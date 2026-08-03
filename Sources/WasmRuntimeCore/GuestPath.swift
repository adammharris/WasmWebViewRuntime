import Foundation

/// The one rule that keeps a path inside the directory it was given.
///
/// This lives here rather than in the app because `WasmWriteback.apply` needs
/// it: every path in a filesystem diff was last touched by guest code, and
/// turning one into a host write without clamping it is how a module that names
/// `../../bin/coreutils.wasm` overwrites a module. The app's `SandboxPath` is a
/// thin wrapper over this with `~` filled in — one implementation, two callers,
/// because a containment rule implemented twice is a containment rule with a
/// hole in it.
public enum GuestPath {

    /// Resolves a path into components relative to a root.
    ///
    /// Resolution happens entirely on an array of components, never by
    /// concatenating strings onto a URL. That is what makes `..` unable to
    /// escape: popping an empty array is a no-op, so no quantity of `../..`
    /// walks above the root.
    ///
    /// - Parameters:
    ///   - path: The path as it arrived. A leading `/` is the root of the
    ///     namespace being resolved against; a leading `~` is ``home``.
    ///   - current: Components of the working directory that a relative path
    ///     resolves against. Pass `[]` for a caller that has already resolved
    ///     to an absolute path.
    ///   - home: What `~` expands to. Pass `[]` for a namespace that has no
    ///     home in it — a guest's preopen is rooted at the working directory it
    ///     was given, and a module writing to a path the host never saw must
    ///     not have a `home` invented underneath it.
    public static func components(
        of path: String,
        relativeTo current: [String],
        home: [String]
    ) -> [String] {
        var input = path
        var result: [String]

        if input.hasPrefix("~") {
            input = String(input.dropFirst())
            result = home
        } else if input.hasPrefix("/") {
            result = []
        } else {
            result = current
        }

        for part in input.split(separator: "/") {
            switch part {
            case ".":
                continue
            case "..":
                // Clamping instead of throwing means `cd ..` at the root is a
                // harmless no-op rather than an error, which matches how a
                // home-directory-rooted shell should feel.
                if !result.isEmpty { result.removeLast() }
            default:
                result.append(String(part))
            }
        }

        return result
    }

    /// Joins resolved components onto `root`. The only place a URL is built.
    public static func url(for components: [String], root: URL) -> URL {
        components.reduce(root) { $0.appending(path: $1) }
    }
}
