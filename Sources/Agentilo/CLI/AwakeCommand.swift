import AgentiloCore
import Foundation

/// `agentilo awake [on|off|status|lid on|lid off]`: keep the Mac awake while agents work.
/// Talks to the running app; without it, edits settings.json.
enum AwakeCommand {
    static let usage = """
    usage: agentilo awake [on | off | status | lid on | lid off]

      on        keep the Mac awake while an agent works (idle sleep)
      off       let it sleep as usual
      lid on    also with the lid closed (needs the helper from Settings → Agents)
      lid off   idle sleep only
      status    print the current state (default)
    """

    static func run(_ args: [String]) async -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            print(usage)
            return 0
        }
        guard let request = AwakeRequest(arguments: args) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 2
        }
        if let data = await HookCommand.post(request, path: "/v1/awake", timeout: 2),
           let status = try? APIJSON.decoder.decode(AwakeStatus.self, from: data) {
            print(status.line)
            return 0
        }
        // App not running: change the file it reads on launch.
        var settings = SettingsStore.load()
        request.apply(to: &settings)
        if request.action != .status { SettingsStore.save(settings) }
        print(AwakeStatus(settings: settings, helperInstalled: KeepAwakeHelper.isInstalled, level: nil, working: 0).line)
        return 0
    }
}
