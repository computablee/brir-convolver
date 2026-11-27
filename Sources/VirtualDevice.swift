import CoreAudio
import Foundation

/// The BRIR Convolver Surround device (Driver/BRIRConvolverDevice.c): a 7.1.4 loopback device that ships
/// inside the app and is installed into /Library/Audio/Plug-Ins/HAL on request.
enum VirtualDevice {
    static let uid = "com.phil.brirconvolver.device.surround"
    static let name = "BRIR Convolver Surround"
    static let bundleName = "BRIRConvolverSurround.driver"
    static let halDirectory = "/Library/Audio/Plug-Ins/HAL"
    static var installedPath: String { "\(halDirectory)/\(bundleName)" }
    static var bundledURL: URL? { Bundle.main.resourceURL?.appendingPathComponent(bundleName) }
    static var isBundled: Bool { bundledURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    /// The device, if Core Audio has loaded it.
    static var deviceID: AudioObjectID? { CA.device(forUID: uid) }

    private static let restartCoreAudio =
        "(/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || /usr/bin/killall coreaudiod)"

    /// Copy the bundled driver into the HAL plug-ins folder and restart Core Audio (asks for an admin password).
    static func install() throws {
        guard let src = bundledURL?.path, isBundled else {
            throw PipelineError("This build doesn't contain the surround device. Rebuild the app with build.sh.")
        }
        try runAsAdmin("/bin/mkdir -p \(q(halDirectory)) && /bin/rm -rf \(q(installedPath)) && "
                       + "/bin/cp -R \(q(src)) \(q(halDirectory))/ && \(restartCoreAudio)")
    }

    static func uninstall() throws {
        try runAsAdmin("/bin/rm -rf \(q(installedPath)) && \(restartCoreAudio)")
    }

    /// Single-quote for the shell.
    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAsAdmin(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { throw PipelineError("Couldn't prepare the install script.") }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let e = error {
            let code = e[NSAppleScript.errorNumber] as? Int
            if code == -128 { throw PipelineError("Cancelled.") }
            throw PipelineError((e[NSAppleScript.errorMessage] as? String) ?? "The install script failed.")
        }
    }
}
