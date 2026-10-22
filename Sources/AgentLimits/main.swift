import AgentLimitsCore
import AppKit

if CommandLine.arguments.contains("--dump") {
    await DumpCommand.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
