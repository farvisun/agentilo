import AgentiloCore
import Foundation

/// `agentilo quiet [on|off|status|<minutes>m|<hours>h]`: silence alerts from a script or a
/// Shortcuts Focus automation. Talks to the running app; without it, edits settings.json.
enum QuietCommand {
    static let usage = """
    usage: agentilo quiet [on | off | status | <minutes>m | <hours>h]

      on        quiet until `agentilo quiet off`
      off       resume alerts (quiet hours on a schedule stay in effect)
      45m, 2h   snooze for a while
      status    print the current state (default)
    """

    static func run(_ args: [String]) async -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            print(usage)
            return 0
        }
        guard let request = QuietRequest(argument: args.first ?? "status") else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 2
        }
        if let data = await HookCommand.post(request, path: "/v1/quiet", timeout: 2),
           let status = try? APIJSON.decoder.decode(QuietStatus.self, from: data) {
            print(status.line)
            return 0
        }
        // App not running: change the file it reads on launch.
        var settings = SettingsStore.load()
        request.apply(to: &settings)
        if request.action != .status { SettingsStore.save(settings) }
        print(QuietStatus(settings.quietReason()).line)
        return 0
    }
}
