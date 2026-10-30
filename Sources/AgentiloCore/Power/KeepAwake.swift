import Foundation
import IOKit.ps

/// How much sleep Agentilo is holding off right now.
public enum KeepAwakeLevel: String, Codable, Equatable, Sendable {
    case off
    /// Idle sleep is blocked with a power assertion (no root). Closing the lid still sleeps.
    case idle
    /// All sleep is blocked, lid closed included, through the root helper (`pmset disablesleep`).
    case lidClosed
}

/// Where the Mac draws power from, and how full the battery is.
public struct PowerSource: Equatable, Sendable {
    public var onBattery: Bool
    /// Battery charge in percent; nil without a battery.
    public var percent: Int?

    public init(onBattery: Bool, percent: Int?) {
        self.onBattery = onBattery
        self.percent = percent
    }

    public static func current() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerSource(onBattery: false, percent: nil)
        }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var percent: Int?
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = current * 100 / max
        }
        return PowerSource(onBattery: type == kIOPSBatteryPowerValue, percent: percent)
    }
}

public enum KeepAwake {
    /// What to hold while `working` agents run. `minBattery` 0 never lets the battery stop it.
    public static func level(
        working: Int, enabled: Bool, lidClosed: Bool, helperInstalled: Bool, power: PowerSource, minBattery: Int
    ) -> KeepAwakeLevel {
        guard enabled, working > 0 else { return .off }
        if power.onBattery, minBattery > 0, let p = power.percent, p < minBattery { return .off }
        return lidClosed && helperInstalled ? .lidClosed : .idle
    }
}

/// The root LaunchDaemon behind "Also with the lid closed". It turns `pmset disablesleep` on
/// while the app keeps a flag file fresh, and back off when the flag goes stale or away, so a
/// quit or crashed app never leaves the Mac unable to sleep.
public enum KeepAwakeHelper {
    public static let label = "app.agentilo.keepawake"
    public static let scriptPath = "/Library/PrivilegedHelperTools/\(label)"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    /// Marks that the helper turned sleep off. Kept on disk (not /var/run) so a reboot in the
    /// middle still finds it and turns sleep back on.
    public static let statePath = "/var/db/\(label).on"
    /// Seconds without a refresh after which the flag counts as stale.
    public static let flagTTL = 90
    /// How often the app rewrites the flag while it holds the lid open.
    public static let flagRefresh: TimeInterval = 20

    public static var flagURL: URL { Paths.appSupport.appendingPathComponent("keep-awake") }

    public static let script = """
    #!/bin/sh
    # agentilo-keepawake 1
    # Installed by Agentilo. Turns all sleep off (lid closed included) while the flag file
    # given as $1 is fresh, and back on when it is stale or gone. Remove it from
    # Agentilo → Settings → Agents → Keep awake.
    flag="$1"
    state="\(statePath)"
    while :; do
      fresh=0
      if [ -f "$flag" ]; then
        age=$(( $(date +%s) - $(stat -f %m "$flag") ))
        [ "$age" -lt \(flagTTL) ] && fresh=1
      fi
      if [ $fresh = 1 ] && [ ! -f "$state" ]; then
        pmset -a disablesleep 1 && touch "$state"
      elif [ $fresh = 0 ] && [ -f "$state" ]; then
        pmset -a disablesleep 0 && rm -f "$state"
      fi
      sleep 5
    done

    """

    public static func plist(flagPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(scriptPath)</string><string>\(xmlEscape(flagPath))</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
        </dict>
        </plist>

        """
    }

    /// Installed and identical to this version's script.
    public static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: plistPath)
            && (try? String(contentsOfFile: scriptPath, encoding: .utf8)) == script
    }

    /// Installed, possibly from an older version (offer an update rather than a fresh install).
    public static var isPresent: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// Root shell command that copies the staged files into root-owned places and loads the daemon.
    public static func installCommand(stagedScript: String, stagedPlist: String) -> String {
        [
            "set -e",
            "install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
            "install -o root -g wheel -m 755 \(shellQuote(stagedScript)) \(scriptPath)",
            "install -o root -g wheel -m 644 \(shellQuote(stagedPlist)) \(plistPath)",
            "launchctl bootout system/\(label) 2>/dev/null || true",
            "launchctl bootstrap system \(plistPath)",
        ].joined(separator: "; ")
    }

    /// Root shell command that unloads the daemon and turns sleep back on if it was holding it.
    public static var uninstallCommand: String {
        [
            "launchctl bootout system/\(label) 2>/dev/null || true",
            "if [ -f \(statePath) ]; then pmset -a disablesleep 0; rm -f \(statePath); fi",
            "rm -f \(plistPath) \(scriptPath)",
        ].joined(separator: "; ")
    }

    /// `do shell script` source that runs `command` as root after an admin password prompt.
    public static func appleScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Body of `POST /v1/awake`, sent by `agentilo awake`.
public struct AwakeRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case on, off, lidOn, lidOff, status }
    public var action: Action

    public init(action: Action) {
        self.action = action
    }

    /// `on`, `off`, `status`, `lid on`, `lid off`.
    public init?(arguments: [String]) {
        let a = arguments.map { $0.lowercased() }
        switch a {
        case [], ["status"]: self.init(action: .status)
        case ["on"]: self.init(action: .on)
        case ["off"]: self.init(action: .off)
        case ["lid", "on"]: self.init(action: .lidOn)
        case ["lid", "off"]: self.init(action: .lidOff)
        default: return nil
        }
    }

    public func apply(to s: inout AppSettings) {
        switch action {
        case .on: s.keepAwake = true
        case .off: s.keepAwake = false
        case .lidOn: s.keepAwakeLidClosed = true
        case .lidOff: s.keepAwakeLidClosed = false
        case .status: break
        }
    }
}

/// Reply to `POST /v1/awake`, and what `agentilo awake status` prints.
public struct AwakeStatus: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var lidClosed: Bool
    public var helperInstalled: Bool
    /// What is held right now; nil when the app is not running.
    public var level: KeepAwakeLevel?
    public var working: Int

    public init(settings s: AppSettings, helperInstalled: Bool, level: KeepAwakeLevel?, working: Int) {
        enabled = s.keepAwake
        lidClosed = s.keepAwakeLidClosed
        self.helperInstalled = helperInstalled
        self.level = level
        self.working = working
    }

    public var line: String {
        guard enabled else { return "Keep awake: off" }
        let mode = lidClosed && helperInstalled ? "lid closed too" : "idle sleep only"
        var out = "Keep awake: on (\(mode))"
        if lidClosed && !helperInstalled { out += "; lid closed needs the helper (Settings → Agents)" }
        switch level {
        case nil: out += "; Agentilo is not running"
        case .off?: out += working > 0 ? "; not holding (battery low)" : "; no agent working"
        case .idle?, .lidClosed?: out += "; holding for \(working) working agent\(working == 1 ? "" : "s")"
        }
        return out
    }
}
