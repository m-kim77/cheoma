import AppKit

@main
enum CheomaApp {
    @MainActor
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--notify") {
            NotifyCommand.send(arguments: Array(CommandLine.arguments[(index + 1)...]))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--agent-statusline") {
            ClaudeStatusLine.run(arguments: Array(CommandLine.arguments[(index + 1)...]))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--agent-event") {
            AgentHooks.send(arguments: Array(CommandLine.arguments[(index + 1)...]))
            return
        }
        if CommandLine.arguments.contains("--agents") {
            AgentsDump.run()
            return
        }
        if CommandLine.arguments.contains("--usage") {
            UsageDump.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--parse-screen") {
            ParseScreenCommand.run(arguments: Array(CommandLine.arguments[(index + 1)...]))
            return
        }
        if CommandLine.arguments.contains("--stats") {
            StatsDump.run()
            return
        }
        if CommandLine.arguments.contains("--menubar-items") {
            MenuBarItemsDump.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--bench") {
            let rest = CommandLine.arguments.dropFirst(index + 1)
            let seconds = rest.first.flatMap(Double.init) ?? 15
            Benchmark.run(seconds: seconds, only: rest.dropFirst().first.flatMap(DashboardTab.init))
            return
        }
        #if DEBUG
        if CommandLine.arguments.contains("--click-test") {
            ClickTest.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render"), index + 1 < CommandLine.arguments.count {
            PreviewRenderer.run(outputDirectory: CommandLine.arguments[index + 1])
            return
        }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Dock 아이콘 없이 메뉴바에서만 동작
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
