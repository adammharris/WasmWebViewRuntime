import Foundation

/// What a `.wasm` file can be used for, read from its bytes.
///
/// A WASI *command* exports `_start` and is a program. A *reactor* exports a
/// library's worth of functions and no entry point: it is driven by a host, and
/// there is nothing for a shell to run. Both are `.wasm`, both are published
/// side by side — quickjs-ng ships `qjs-wasi.wasm` next to
/// `qjs-wasi-reactor.wasm` — so a name cannot settle it and the export table
/// has to.
///
/// Both runtimes already refuse a reactor, but only once the user runs it: an
/// interpreter checks its parsed exports and the web worker checks
/// `typeof instance.exports._start`. By then it is installed, on the `PATH`,
/// and the failure reads as a trap rather than as a bad download. Reading the
/// export section costs a walk over the section headers, so an installer can
/// know the same thing before it writes anything.
public enum WasmModuleShape: Sendable, Equatable {
    /// Exports `_start`, as a function. Runnable.
    case command
    /// A well-formed core module with no entry point.
    case reactor
    /// Not a core module: wrong magic, a component, or bytes we cannot walk.
    case notAModule

    /// Section 7 of the binary format. Everything before it gets skipped by its
    /// declared length, so this never has to understand types, code, or a
    /// custom section's payload.
    private static let exportSectionID: UInt8 = 7
    /// Kind 0 in an export entry. The web backend calls `_start()`, so a
    /// `_start` that is a global or a table is not an entry point either.
    private static let functionKind: UInt8 = 0
    private static let startExport = Array("_start".utf8)

    /// Why this cannot be installed as a command, or nil if it can.
    public var complaint: String? {
        switch self {
        case .command:
            nil
        case .reactor:
            "not a program — a WASI reactor exports no _start and has to be driven by a host"
        case .notAModule:
            "not a WebAssembly core module"
        }
    }

    public static func of(_ bytes: Data) -> WasmModuleShape {
        var cursor = bytes.startIndex
        let end = bytes.endIndex

        func next() -> UInt8? {
            guard cursor < end else { return nil }
            defer { cursor = bytes.index(after: cursor) }
            return bytes[cursor]
        }

        /// Unsigned LEB128, capped at the five groups a u32 can occupy. A sixth
        /// means these are not the bytes we think they are.
        func varint() -> Int? {
            var value = 0
            var shift = 0
            while shift <= 28 {
                guard let byte = next() else { return nil }
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        // `\0asm`, then a version word. A core module is version 1; the
        // component model reuses the magic and puts a layer in the high half,
        // which is why this checks all four bytes rather than just the first.
        guard bytes.count >= 8 else { return .notAModule }
        guard next() == 0x00, next() == 0x61, next() == 0x73, next() == 0x6D else {
            return .notAModule
        }
        guard next() == 0x01, next() == 0x00, next() == 0x00, next() == 0x00 else {
            return .notAModule
        }

        while cursor < end {
            guard let id = next(), let size = varint(), size >= 0,
                bytes.distance(from: cursor, to: end) >= size
            else { return .notAModule }
            let sectionEnd = bytes.index(cursor, offsetBy: size)

            if id == exportSectionID {
                guard let count = varint() else { return .notAModule }
                for _ in 0 ..< count {
                    guard let length = varint(), length >= 0,
                        bytes.distance(from: cursor, to: sectionEnd) >= length
                    else { return .notAModule }
                    let nameEnd = bytes.index(cursor, offsetBy: length)
                    let name = bytes[cursor ..< nameEnd]
                    cursor = nameEnd

                    guard let kind = next(), varint() != nil else { return .notAModule }
                    if kind == functionKind, name.elementsEqual(startExport) { return .command }
                }
            }

            cursor = sectionEnd
        }

        // Walked the whole file cleanly and no `_start` came out of it.
        return .reactor
    }
}
