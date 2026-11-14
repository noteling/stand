import AVFoundation
import Foundation
import StandCore

/// What this Mac gives Stand to work with, as a few lines of text: which build, whether
/// there is a key, whether the microphone is allowed, where the brain is and whether it
/// answers to its name, and how many notes there are. Nothing secret is in it.
///
///   Stand --probe doctor
///
/// It is the first thing to ask for when Stand misbehaves on a Mac nobody here can see,
/// and it goes into every problem report (`ProblemReport`).
enum Doctor {
    static func report(root: URL) -> String {
        var lines = [String]()
        let info = Bundle.main.infoDictionary ?? [:]
        let build = info["StandBuild"] as? String
        lines.append("Stand: \(build.map { "build \($0), packaged" } ?? "built from the repo")")
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var machine = "unknown"
        var size = 0
        if sysctlbyname("hw.machine", nil, &size, nil, 0) == 0 {
            var chars = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.machine", &chars, &size, nil, 0) == 0 { machine = String(cString: chars) }
        }
        lines.append("macOS: \(system.majorVersion).\(system.minorVersion).\(system.patchVersion), \(machine)")
        lines.append("Stand's folder: \(root.path)")
        lines.append("Key for the voice: \((try? Project.geminiKey(root: root)) == nil ? "MISSING" : "there")")
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "allowed"
        case .denied: microphone = "REFUSED (System Settings > Privacy & Security > Microphone)"
        case .restricted: microphone = "not permitted on this Mac"
        default: microphone = "not asked yet (macOS asks when the first session starts)"
        }
        lines.append("Microphone: \(microphone)")

        let settings = BrainSettings.load(root: root)
        if let missing = BrainFactory.missing(root: root) {
            lines.append("Brain: NONE. \(missing)")
        } else if BrainFactory.mode(root: root) == "claudeCode", let claude = BrainFactory.claudeCLI(root: root) {
            let version = (try? run(claude, ["--version"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lines.append("Brain: Claude Code at \(claude) (\(version.isEmpty ? "it did not answer --version" : version)), model \(settings.model.isEmpty ? "its default" : settings.model)")
            lines.append("  may use: \(settings.web ? "the web" : "no web")\(settings.claudeCodeSetup ? ", this Mac's own Claude Code setup" : "")\(settings.mcpConfig.isEmpty ? "" : ", \(settings.mcpConfig)"); asks before: \(settings.ask)")
        } else {
            lines.append("Brain: the Messages API (\(settings.apiBaseURL.isEmpty ? "direct" : settings.apiBaseURL))")
        }
        let library = NotesLibrary(root: root, settings: settings)
        let notes = library.current()
        lines.append("Notes: \(notes.isEmpty ? "none" : notes.summary)")
        for problem in library.problems + notes.leftOut { lines.append("  \(problem)") }
        for status in LinkedRepos.statuses(root: root, sources: library.sources) { lines.append("  \(status.line())") }
        let brief = Project.brief(root: root)
        lines.append("Brief: \(brief.isEmpty ? "none" : "\(brief.count) characters")")
        let runs = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("runs").path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        lines.append("Sessions kept: \(runs.count)\(runs.last.map { ", the last one \($0)" } ?? "")")
        if let spend = Spend.total(root: root).line { lines.append("  \(spend)") }
        return lines.joined(separator: "\n")
    }

    /// Runs a program and returns what it printed. Five seconds at most.
    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Installed through Node, the CLI is a script that needs the `node` beside it, which an app's own PATH does not have.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: path).deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
