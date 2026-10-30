import AgentiloCore
import Foundation
import IOKit.pwr_mgt

/// Holds the idle-sleep power assertion and keeps the lid-closed helper's flag file fresh.
@MainActor
final class SleepGuard {
    private var assertion: IOPMAssertionID = 0
    private var flagWrittenAt: Date?

    init() {
        // A flag left by a crash is stale within 90 s anyway; drop it right away.
        try? FileManager.default.removeItem(at: KeepAwakeHelper.flagURL)
    }

    func hold(_ level: KeepAwakeLevel) {
        if level == .off {
            if assertion != 0 {
                IOPMAssertionRelease(assertion)
                assertion = 0
            }
        } else if assertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Agentilo: an agent is working" as CFString,
                &assertion
            )
        }
        if level == .lidClosed {
            if Date().timeIntervalSince(flagWrittenAt ?? .distantPast) >= KeepAwakeHelper.flagRefresh {
                try? Data().write(to: KeepAwakeHelper.flagURL)
                flagWrittenAt = Date()
            }
        } else if flagWrittenAt != nil {
            try? FileManager.default.removeItem(at: KeepAwakeHelper.flagURL)
            flagWrittenAt = nil
        }
    }
}

/// Keep the Mac awake while agents work: idle sleep through a power assertion, lid closed
/// through the root helper.
extension AppState {
    var workingAgents: Int { agents.sessions.values.filter { $0.state == .working }.count }

    func updateKeepAwake() {
        let level = KeepAwake.level(
            working: workingAgents, enabled: settings.keepAwake, lidClosed: settings.keepAwakeLidClosed,
            helperInstalled: keepAwakeHelperInstalled, power: .current(), minBattery: settings.keepAwakeMinBattery
        )
        sleepGuard.hold(level)
        if keepAwakeLevel != level { keepAwakeLevel = level }
    }

    var awakeStatus: AwakeStatus {
        AwakeStatus(settings: settings, helperInstalled: keepAwakeHelperInstalled, level: keepAwakeLevel, working: workingAgents)
    }

    /// Asks for an admin password and installs the helper. Returns an error to show, if any.
    func installKeepAwakeHelper() async -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentilo-keepawake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("helper.sh"), plist = dir.appendingPathComponent("helper.plist")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try KeepAwakeHelper.script.write(to: script, atomically: true, encoding: .utf8)
            try KeepAwakeHelper.plist(flagPath: KeepAwakeHelper.flagURL.path).write(to: plist, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        let error = await Self.runAsAdmin(KeepAwakeHelper.installCommand(stagedScript: script.path, stagedPlist: plist.path))
        helperChanged()
        return error
    }

    func removeKeepAwakeHelper() async -> String? {
        let error = await Self.runAsAdmin(KeepAwakeHelper.uninstallCommand)
        helperChanged()
        return error
    }

    private func helperChanged() {
        keepAwakeHelperInstalled = KeepAwakeHelper.isInstalled
        updateKeepAwake()
    }

    /// Runs a shell command as root through the standard macOS admin prompt.
    private nonisolated static func runAsAdmin(_ command: String) async -> String? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", KeepAwakeHelper.appleScript(command)]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return error.localizedDescription }
            p.waitUntilExit()
            guard p.terminationStatus != 0 else { return nil }
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("-128") { return "Cancelled" }
            return msg.isEmpty ? "The helper could not be changed" : msg
        }.value
    }
}
