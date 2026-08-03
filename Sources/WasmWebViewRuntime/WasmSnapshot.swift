import Foundation
import WasmRuntimeCore

/// One directory the guest can reach, and the terms it reaches it on.
///
/// The web view backend has no host filesystem to hand a guest, so a preopen
/// stops being a path and becomes a payload: a tree read out of the sandbox on
/// the way in and a diff applied back to it on the way out. `readOnly` stops
/// being advisory here — a mount declared read-only has its write-backs
/// dropped, because unlike an interpreter handing out a real directory this
/// backend actually gets to choose.
public struct WasmPreopen: Sendable {
    public let guestPath: String
    public let hostURL: URL
    public let readOnly: Bool

    public init(guestPath: String, hostURL: URL, readOnly: Bool) {
        self.guestPath = guestPath
        self.hostURL = hostURL
        self.readOnly = readOnly
    }

    /// The guest's working directory is always the first preopen. See
    /// `WasmProgram.mounts` for why that ordering is load-bearing.
    public static func all(for program: WasmProgram) -> [WasmPreopen] {
        [WasmPreopen(guestPath: "/", hostURL: program.root, readOnly: false)]
            + program.mounts.map {
                WasmPreopen(guestPath: $0.guestPath, hostURL: $0.hostURL, readOnly: $0.readOnly)
            }
    }
}

/// A directory tree, flattened into something that can cross into JavaScript.
///
/// The wire format is deliberately dumb — a header and a run of length-prefixed
/// entries — because the reader is a `DataView` in a worker and the only thing
/// that matters on an 18 MB standard library is that neither side allocates per
/// file more than it has to. JSON with base64 bodies was the alternative and
/// costs roughly 2x in bytes and considerably more in parse time.
///
/// ```
/// "WSHF" u32 version u32 entryCount
/// entry: u8 kind, u32 pathLen, u32 dataLen, u32 mode, f64 mtime, path…, data…
/// ```
///
/// Paths are relative to the preopen root, `/`-separated, with no leading
/// slash, and sorted — which puts every parent ahead of its children, so the
/// reader can build the tree in one pass without ever looking a parent up.
public enum WasmSnapshot {
    public static let magic: [UInt8] = Array("WSHF".utf8)
    public static let version: UInt32 = 1

    public enum Kind: UInt8 {
        case directory = 0
        case file = 1
        case symlink = 2
    }

    /// What a single preopen is allowed to weigh.
    ///
    /// Copying is the whole cost model of this backend, and the failure it
    /// guards against is not slowness but the jetsam killing the app: the
    /// bytes exist twice at the peak, once in `Data` and once in the web
    /// content process. A tree over the limit is a clear error at the top of
    /// the run rather than a crash somewhere in the middle of it.
    public static let byteLimit = 192 << 20
    public static let entryLimit = 200_000

    /// Reads a host directory into a snapshot.
    ///
    /// Walks with `lstat` rather than `FileManager`'s enumerator: one syscall
    /// per entry answers type, size, mode, and mtime together, where the URL
    /// path would be a resource-value fetch plus an `attributesOfItem` and
    /// several thousand `URL`s that exist only to be thrown away.
    /// - Parameter overlay: Package files to place in the guest's view of this
    ///   directory without them existing in it. Their parent directories are
    ///   synthesised, because the reader builds the tree in one pass and needs
    ///   every parent to arrive first.
    public static func pack(_ root: URL, overlay: [WasmOverlay] = []) throws -> Data {
        var entries: [Entry] = []
        try walk(root: root.path, relative: "", into: &entries)

        var injected: Set<String> = []
        for file in overlay {
            guard let data = try? Data(contentsOf: file.hostURL, options: .mappedIfSafe) else {
                continue
            }
            let components = file.guestPath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            // Parents first, and only the ones the real tree does not already
            // have — an overlay must not replace a directory of the user's.
            var prefix: [String] = []
            for parent in components.dropLast() {
                prefix.append(parent)
                let path = prefix.joined(separator: "/")
                guard injected.insert(path).inserted,
                      !entries.contains(where: { $0.path == path })
                else { continue }
                entries.append(
                    Entry(path: path, kind: .directory, mode: 0o755, mtime: 0, data: Data()))
            }

            let path = components.joined(separator: "/")
            // The user's own file wins. A package cannot shadow something the
            // user put there, whatever it declared.
            guard !entries.contains(where: { $0.path == path }) else { continue }
            entries.append(
                Entry(path: path, kind: .file, mode: 0o644, mtime: 0, data: data))
        }

        entries.sort { $0.path < $1.path }

        var total = 0
        for entry in entries { total += entry.data.count }
        guard total <= byteLimit else {
            throw WasmRuntimeError.trapped(
                "\(root.lastPathComponent): \(total >> 20) MB is too much to copy into the "
                    + "web view (limit \(byteLimit >> 20) MB) — use the interpreter backend"
            )
        }

        var out = Data(capacity: total + entries.count * 32 + 12)
        out.append(contentsOf: magic)
        out.appendLittle(version)
        out.appendLittle(UInt32(entries.count))
        for entry in entries {
            let path = Array(entry.path.utf8)
            out.append(entry.kind.rawValue)
            out.appendLittle(UInt32(path.count))
            out.appendLittle(UInt32(entry.data.count))
            out.appendLittle(entry.mode)
            out.appendLittle(entry.mtime.bitPattern)
            out.append(contentsOf: path)
            out.append(entry.data)
        }
        return out
    }

    private struct Entry {
        let path: String
        let kind: Kind
        let mode: UInt32
        let mtime: Double
        let data: Data
    }

    private static func walk(root: String, relative: String, into entries: inout [Entry]) throws {
        let directory = relative.isEmpty ? root : "\(root)/\(relative)"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []

        for name in names {
            let path = relative.isEmpty ? name : "\(relative)/\(name)"
            let full = "\(root)/\(path)"

            var info = stat()
            guard lstat(full, &info) == 0 else { continue }

            guard entries.count < entryLimit else {
                throw WasmRuntimeError.trapped(
                    "too many files to copy into the web view "
                        + "(limit \(entryLimit)) — use the interpreter backend"
                )
            }

            let mode = UInt32(info.st_mode) & 0o7777
            let mtime =
                Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1e9

            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                entries.append(
                    Entry(path: path, kind: .directory, mode: mode, mtime: mtime, data: Data()))
                try walk(root: root, relative: path, into: &entries)

            case S_IFLNK:
                // The target is stored verbatim and resolved by the guest's
                // own path walk, so a link pointing outside the preopen simply
                // fails to resolve there — the same thing WASI does.
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? ""
                entries.append(
                    Entry(
                        path: path, kind: .symlink, mode: mode, mtime: mtime,
                        data: Data(target.utf8)))

            case S_IFREG:
                // Mapped rather than read: a module the guest never opens
                // costs address space instead of resident memory, and the
                // pages that do get touched are the ones being copied out.
                let data =
                    (try? Data(contentsOf: URL(filePath: full), options: .mappedIfSafe)) ?? Data()
                entries.append(
                    Entry(path: path, kind: .file, mode: mode, mtime: mtime, data: data))

            default:
                // Sockets, fifos, devices. Nothing the sandbox produces, and
                // nothing with a meaningful in-memory equivalent.
                continue
            }
        }
    }

    /// A cheap identity for a tree, so a read-only mount is copied once per
    /// install rather than once per run.
    ///
    /// This is what a read-only mount declaration exists to feed. It hashes
    /// structure and timestamps, not contents — a tree whose files changed
    /// without their size or mtime changing will read stale, which is the same
    /// bet a compiled-module cache already makes and the same one `make` has
    /// made for fifty years.
    public static func signature(of root: URL) -> String {
        var hasher = Hasher()
        var stack = [root.path]
        var count = 0

        while let directory = stack.popLast(), count < entryLimit {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                .sorted()
            for name in names {
                let full = "\(directory)/\(name)"
                var info = stat()
                guard lstat(full, &info) == 0 else { continue }
                hasher.combine(full)
                hasher.combine(info.st_size)
                hasher.combine(info.st_mtimespec.tv_sec)
                hasher.combine(info.st_mtimespec.tv_nsec)
                hasher.combine(info.st_mode)
                count += 1
                if info.st_mode & S_IFMT == S_IFDIR { stack.append(full) }
            }
        }
        return String(UInt(bitPattern: hasher.finalize()), radix: 36)
    }
}

/// What the guest changed, on its way back to the sandbox.
///
/// ```
/// "WSHW" u32 version
/// u32 changedCount, entry: u32 preopen, u8 kind, u32 pathLen, u32 dataLen,
///                          u32 mode, f64 mtime, path…, data…
/// u32 deletedCount, entry: u32 preopen, u32 pathLen, path…
/// ```
///
/// The diff carries only what the guest actually created or modified, which is
/// also what makes concurrent guests safe. Two stages of a pipeline share a
/// working directory, and both snapshot it and both write back — but each one
/// writes back only its own changes, so they collide only if they wrote the
/// same file, which is a race under the interpreter too.
///
/// What is genuinely different from the interpreter is *when*: WasmKit's writes
/// land as the guest makes them, these land at exit. A program that writes a
/// file and then traps leaves it behind there and does not here.
///
/// Every path here was last touched by guest code, so none of it is trusted.
/// `apply` resolves each one through `GuestPath` against the preopen it claims
/// to belong to — the same component-array rule the embedding shell's own
/// filesystem uses, which is exactly why that rule sits in `WasmRuntimeCore`
/// rather than in the app: a write-back naming `../../bin/coreutils.wasm` has
/// to land harmlessly inside the preopen instead of overwriting a module, and
/// two implementations of that would be one too many.
public enum WasmWriteback {
    public static let magic: [UInt8] = Array("WSHW".utf8)

    public struct Change {
        public let preopen: Int
        public let kind: WasmSnapshot.Kind
        public let path: String
        public let mode: UInt32
        public let mtime: Double
        public let data: Data

        public init(
            preopen: Int,
            kind: WasmSnapshot.Kind,
            path: String,
            mode: UInt32,
            mtime: Double,
            data: Data
        ) {
            self.preopen = preopen
            self.kind = kind
            self.path = path
            self.mode = mode
            self.mtime = mtime
            self.data = data
        }
    }

    public struct Deletion {
        public let preopen: Int
        public let path: String

        public init(preopen: Int, path: String) {
            self.preopen = preopen
            self.path = path
        }
    }

    public struct Result {
        public var changes: [Change] = []
        public var deletions: [Deletion] = []

        public init(changes: [Change] = [], deletions: [Deletion] = []) {
            self.changes = changes
            self.deletions = deletions
        }
    }

    public static func parse(_ data: Data) throws -> Result {
        var reader = ByteReader(data)
        guard try reader.bytes(4).elementsEqual(magic), try reader.u32() == 1 else {
            throw WasmRuntimeError.trapped("the web view returned a filesystem diff we cannot read")
        }

        var result = Result()
        let changed = try reader.u32()
        result.changes.reserveCapacity(Int(changed))
        for _ in 0 ..< changed {
            let preopen = Int(try reader.u32())
            let rawKind = try reader.u8()
            let pathLength = Int(try reader.u32())
            let dataLength = Int(try reader.u32())
            let mode = try reader.u32()
            let mtime = Double(bitPattern: try reader.u64())
            let path = String(decoding: try reader.bytes(pathLength), as: UTF8.self)
            let body = try reader.data(dataLength)
            guard let kind = WasmSnapshot.Kind(rawValue: rawKind) else { continue }
            result.changes.append(
                Change(preopen: preopen, kind: kind, path: path, mode: mode, mtime: mtime,
                       data: body))
        }

        let deleted = try reader.u32()
        result.deletions.reserveCapacity(Int(deleted))
        for _ in 0 ..< deleted {
            let preopen = Int(try reader.u32())
            let pathLength = Int(try reader.u32())
            let path = String(decoding: try reader.bytes(pathLength), as: UTF8.self)
            result.deletions.append(Deletion(preopen: preopen, path: path))
        }
        return result
    }

    /// Replays the diff onto the sandbox.
    ///
    /// Deletions run first so that the `rm -rf dir && mkdir dir/x` shape lands
    /// in the right order. The guest reports deletions as "paths that were in
    /// the snapshot and are not in the tree now", so nothing it still holds can
    /// appear in both lists.
    ///
    /// Best-effort per entry rather than transactional: a write that fails
    /// leaves the rest of the diff to land, because the run has already
    /// happened and the alternative to a partial result is no result. Failures
    /// are collected and returned so the caller can say so.
    /// - Parameter overlay: Paths in preopen 0 that the package put in the
    ///   guest's view and that must not reach the disk. Without this an
    ///   overlay is one `chmod` away from becoming a real file in the user's
    ///   home — the guest can write to it, and a write-back is how anything
    ///   gets there.
    @discardableResult
    public static func apply(
        _ result: Result,
        to preopens: [WasmPreopen],
        overlay: Set<String> = []
    ) -> [String] {
        var problems: [String] = []
        let manager = FileManager.default

        /// The overlay lives in the working directory, which is preopen 0.
        func isOverlay(_ path: String, _ index: Int) -> Bool {
            guard index == 0, !overlay.isEmpty else { return false }
            let normalized = GuestPath.components(of: path, relativeTo: [], home: [])
                .joined(separator: "/")
            // The file itself, and the directories that exist only to hold it.
            return overlay.contains(normalized)
                || overlay.contains { $0.hasPrefix(normalized + "/") }
        }

        func resolve(_ path: String, _ index: Int) -> (url: URL, preopen: WasmPreopen)? {
            guard preopens.indices.contains(index) else { return nil }
            let preopen = preopens[index]
            // No home in a preopen: `~` is the top of what the guest was
            // given, which is the same clamp `..` gets.
            let components = GuestPath.components(of: path, relativeTo: [], home: [])
            // An empty component list is the preopen root itself. Nothing the
            // guest can say should let it replace or remove its own mount.
            guard !components.isEmpty else { return nil }
            return (GuestPath.url(for: components, root: preopen.hostURL), preopen)
        }

        for deletion in result.deletions {
            guard let (url, preopen) = resolve(deletion.path, deletion.preopen) else { continue }
            guard !preopen.readOnly else { continue }
            guard !isOverlay(deletion.path, deletion.preopen) else { continue }
            if manager.fileExists(atPath: url.path) {
                do { try manager.removeItem(at: url) } catch {
                    problems.append("\(deletion.path): \(error.localizedDescription)")
                }
            }
        }

        // Sorted so a directory is created before anything inside it, whatever
        // order the guest walked its own tree in.
        for change in result.changes.sorted(by: { $0.path < $1.path }) {
            guard let (url, preopen) = resolve(change.path, change.preopen) else { continue }
            guard !preopen.readOnly else { continue }
            guard !isOverlay(change.path, change.preopen) else { continue }

            do {
                try manager.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

                switch change.kind {
                case .directory:
                    if !manager.fileExists(atPath: url.path) {
                        try manager.createDirectory(at: url, withIntermediateDirectories: true)
                    }

                case .file:
                    try change.data.write(to: url, options: .atomic)

                case .symlink:
                    let target = String(decoding: change.data, as: UTF8.self)
                    try? manager.removeItem(at: url)
                    try manager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
                }

                if change.kind != .symlink {
                    // The execute bit is the shell's trust model, so a mode
                    // the guest set has to survive the trip back — `zig` marks
                    // what it builds executable and `chmod +x` has to mean it.
                    try? manager.setAttributes(
                        [
                            .posixPermissions: NSNumber(value: change.mode),
                            .modificationDate: Date(timeIntervalSince1970: change.mtime),
                        ],
                        ofItemAtPath: url.path)
                }
            } catch {
                problems.append("\(change.path): \(error.localizedDescription)")
            }
        }

        return problems
    }
}

// MARK: - Wire helpers

extension Data {
    fileprivate mutating func appendLittle(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }

    fileprivate mutating func appendLittle(_ value: UInt64) {
        appendLittle(UInt32(truncatingIfNeeded: value))
        appendLittle(UInt32(truncatingIfNeeded: value >> 32))
    }
}

/// A bounds-checked cursor. The bytes come from JavaScript, so "the length
/// field says 4 GB" has to be an error and not a crash.
private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    private mutating func advance(_ count: Int) throws -> Range<Int> {
        guard count >= 0, offset + count <= data.endIndex else {
            throw WasmRuntimeError.trapped("truncated filesystem diff from the web view")
        }
        defer { offset += count }
        return offset ..< (offset + count)
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] { Array(data[try advance(count)]) }
    mutating func data(_ count: Int) throws -> Data { data[try advance(count)] }

    mutating func u8() throws -> UInt8 { try bytes(1)[0] }

    mutating func u32() throws -> UInt32 {
        let raw = try bytes(4)
        return UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
    }

    mutating func u64() throws -> UInt64 {
        let low = UInt64(try u32())
        return low | UInt64(try u32()) << 32
    }
}
