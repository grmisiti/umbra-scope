import AppKit
import CryptoKit

/// Installs the Umbra Link OFX plugin that ships inside the app into /Library/OFX/Plugins, where DaVinci Resolve
/// looks for it. That folder belongs to root, so the copy runs through the standard macOS administrator prompt.
/// Only UmbraLink.ofx.bundle is ever touched — other vendors' plugins in the same folder are left alone.
enum PluginInstaller {
    static let installed = URL(fileURLWithPath: "/Library/OFX/Plugins/UmbraLink.ofx.bundle")
    static var bundled: URL? { Bundle.main.url(forResource: "UmbraLink", withExtension: "ofx.bundle") }

    enum State { case notInstalled, outdated, current, unavailable }

    /// Whether the installed plugin is the one this app carries (compared by the plugin binary's SHA-256).
    static var state: State {
        guard let b = bundled else { return .unavailable }
        guard FileManager.default.fileExists(atPath: installed.path) else { return .notInstalled }
        return digest(binary(of: installed)) == digest(binary(of: b)) && digest(binary(of: b)) != nil ? .current : .outdated
    }

    static var resolveIsInstalled: Bool {
        ["/Applications/DaVinci Resolve/DaVinci Resolve.app", "/Applications/DaVinci Resolve Studio/DaVinci Resolve.app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    private static func binary(of bundle: URL) -> URL { bundle.appendingPathComponent("Contents/MacOS/UmbraLink.ofx") }

    private static func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Single-quoted for the shell.
    private static func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The shell commands run as administrator. Owned by root and not writable by others, so code that Resolve loads
    /// can't be replaced without the password; the quarantine flag from the download is removed so Resolve can load it.
    /// The bundle is first copied into a staging folder only root can enter, and checked there: the plugin binary must
    /// hash to the digest the app read when you clicked Install, the bundle must carry no symbolic links and its code
    /// signature must be intact. Only then does it replace the installed copy, so something swapped into the app
    /// between the click and the password prompt is refused instead of installed as root.
    static func installCommand(destination: String = installed.path, staging: String = "/private/var/tmp") -> String? {
        guard let b = bundled, let expected = digest(binary(of: b)) else { return nil }
        let dst = sh(destination), parent = sh((destination as NSString).deletingLastPathComponent)
        let src = sh(b.path)
        let staged = "$S/UmbraLink.ofx.bundle"
        let checks = [
            "ditto \(src) \(staged)",
            "[ -z \"$(find \(staged) -type l)\" ] || { echo 'the plugin contains symbolic links' >&2; exit 1; }",
            "[ \"$(shasum -a 256 \(staged)/Contents/MacOS/UmbraLink.ofx | cut -d' ' -f1)\" = \(expected) ] || { echo 'the plugin changed after the app read it' >&2; exit 1; }",
            "codesign --verify --strict \(staged) || { echo 'the plugin signature is not intact' >&2; exit 1; }",
            "(xattr -dr com.apple.quarantine \(staged) 2>/dev/null || true)",
            "chown -R root:wheel \(staged)", "chmod -R go-w \(staged)",
            "mkdir -p \(parent)", "rm -rf \(dst)", "mv \(staged) \(dst)",
        ].joined(separator: "; ")
        return "S=$(mktemp -d \(sh(staging))/umbralink.XXXXXX) || exit 1; (set -e; \(checks)); rc=$?; rm -rf $S; exit $rc"
    }

    static func uninstallCommand() -> String { "rm -rf \(sh(installed.path))" }

    /// Runs commands with the macOS administrator prompt. Returns nil on success, or a message (nil also when the
    /// person cancels the prompt, with `cancelled` set).
    @discardableResult
    static func runAsAdmin(_ command: String, cancelled: inout Bool) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { cancelled = true; return nil }
        return error[NSAppleScript.errorMessage] as? String ?? "\(error)"
    }

    /// Installs (or updates) and tells the person how it went.
    static func install() {
        guard let cmd = installCommand() else { return alert("The plugin is missing from this copy of Umbra Scope.") }
        var cancelled = false
        if let err = runAsAdmin(cmd, cancelled: &cancelled) { return alert("The plugin could not be installed.\n\n\(err)") }
        if cancelled { return }
        alert("Umbra Link is installed.", info: "Restart DaVinci Resolve, then add the Umbra Link node (OpenFX library) on the Color page.")
    }

    static func uninstall() {
        var cancelled = false
        if let err = runAsAdmin(uninstallCommand(), cancelled: &cancelled) { return alert("The plugin could not be removed.\n\n\(err)") }
        if !cancelled { alert("Umbra Link was removed.", info: "Restart DaVinci Resolve to unload it.") }
    }

    /// On launch: offers to install or update when Resolve is present, unless the person said not to ask again.
    static func offerIfNeeded() {
        guard resolveIsInstalled, !UserDefaults.standard.bool(forKey: "pluginPromptOff") else { return }
        let s = state
        guard s == .notInstalled || s == .outdated else { return }
        let a = NSAlert()
        a.messageText = s == .notInstalled ? "Install the Umbra Link plugin for DaVinci Resolve?"
                                           : "Update the Umbra Link plugin for DaVinci Resolve?"
        a.informativeText = "It sends the picture of a Resolve node to Umbra Scope. macOS will ask for an administrator password."
        a.addButton(withTitle: s == .notInstalled ? "Install" : "Update")
        a.addButton(withTitle: "Not Now")
        a.addButton(withTitle: "Don't Ask Again")
        switch a.runModal() {
        case .alertFirstButtonReturn: install()
        case .alertThirdButtonReturn: UserDefaults.standard.set(true, forKey: "pluginPromptOff")
        default: break
        }
    }

    private static func alert(_ text: String, info: String = "") {
        let a = NSAlert()
        a.messageText = text
        a.informativeText = info
        a.runModal()
    }
}
