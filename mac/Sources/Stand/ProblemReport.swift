import Foundation
import StandCore

/// One file to send when Stand misbehaves on a Mac nobody here can see: what `Doctor`
/// says about this Mac, and the last session's record. It is made in Stand's folder,
/// under `reports/`, and nothing is sent anywhere: the person sends it themselves.
///
///   Stand --probe report
///
/// In it: doctor.txt, brain.json (header values left out), and from the last session its
/// events, transcript, summary, instructions and the recording as a small audio file.
/// Never in it: .env, the notes, or any other session.
enum ProblemReport {
    static func make(root: URL) throws -> URL {
        let manager = FileManager.default
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let name = "Stand-report-\(stamp.string(from: Date()))"
        let reports = root.appendingPathComponent("reports")
        // A folder of its own for each report: two can be asked for at once.
        let staging = manager.temporaryDirectory.appendingPathComponent("stand-report-\(UUID().uuidString)/\(name)")
        try? manager.removeItem(at: staging.deletingLastPathComponent())
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging.deletingLastPathComponent()) }

        try Doctor.report(root: root).write(to: staging.appendingPathComponent("doctor.txt"), atomically: true, encoding: .utf8)

        // brain.json as it is, except that what a header is set to may be a secret.
        if let data = try? Data(contentsOf: BrainSettings.file(root: root)),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let headers = json["apiHeaders"] as? [String: Any] { json["apiHeaders"] = headers.mapValues { _ in "(left out)" } }
            let clean = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try clean.write(to: staging.appendingPathComponent("brain.json"))
        }

        let runs = root.appendingPathComponent("runs")
        // The last session, finished or not. Other things are kept in runs too, such as a probe's recordings.
        let last = ((try? manager.contentsOfDirectory(atPath: runs.path)) ?? []).sorted()
            .last { manager.fileExists(atPath: runs.appendingPathComponent($0).appendingPathComponent("events.jsonl").path) }
        if let last {
            let from = runs.appendingPathComponent(last)
            let to = staging.appendingPathComponent(last)
            try manager.createDirectory(at: to, withIntermediateDirectories: true)
            for file in ["events.jsonl", "transcript.md", "summary.json", "instructions.md", "report.md", "discussion.json"] {
                try? manager.copyItem(at: from.appendingPathComponent(file), to: to.appendingPathComponent(file))
            }
            // The recording, small enough to send: about a quarter of a megabyte a minute.
            let recording = from.appendingPathComponent("recording.wav")
            if manager.fileExists(atPath: recording.path) {
                try? run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", "32000", recording.path, to.appendingPathComponent("recording.m4a").path])
            }
        }

        try manager.createDirectory(at: reports, withIntermediateDirectories: true)
        let zip = reports.appendingPathComponent(name + ".zip")
        try? manager.removeItem(at: zip)
        try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", staging.path, zip.path])
        return zip
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StandError("\(path) failed with status \(process.terminationStatus).") }
    }
}
