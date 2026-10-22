// 同じ合成音声をDictationTranscriberの句読点ON/OFFで比較する。録音・文字入力は行わない。
import Foundation
import AVFoundation
import Speech
import CoreMedia

@main struct AudioComparison {
    @MainActor static func main() async throws {
        let jobs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: String]]
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw failure("output-exists") }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        for (index, job) in jobs.enumerated() {
            for enabled in (index.isMultiple(of: 2) ? [true, false] : [false, true]) {
                let module = DictationTranscriber(locale: Locale(identifier: "ja-JP"), contentHints: [.farField],
                    transcriptionOptions: enabled ? [.punctuation] : [],
                    reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange])
                if await AssetInventory.status(forModules: [module]) != .installed {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                        try await request.downloadAndInstall()
                    }
                }
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: job["path"]!))
                let duration = Double(file.length) / file.processingFormat.sampleRate
                let analyzer = SpeechAnalyzer(modules: [module])
                let start = ContinuousClock.now
                let resultTask = Task { () throws -> [[String: Any]] in
                    var events: [[String: Any]] = []
                    for try await result in module.results {
                        let elapsed = start.duration(to: .now)
                        let attributes: [[String: Any]] = result.text.runs.compactMap { run in
                            guard let range = run.audioTimeRange else { return nil }
                            return ["text": String(result.text[run.range].characters),
                                    "start": CMTimeGetSeconds(range.start), "end": CMTimeGetSeconds(CMTimeRangeGetEnd(range))]
                        }
                        events.append(["text": String(result.text.characters), "is_final": result.isFinal,
                            "start": CMTimeGetSeconds(result.range.start), "end": CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)),
                            "received_ms": Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
                            "timed_runs": attributes])
                    }
                    return events
                }
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                let events = try await resultTask.value
                var finals: [String: [String: Any]] = [:]
                for event in events where event["is_final"] as! Bool {
                    finals["\(event["start"]!):\(event["end"]!)"] = event
                }
                let text = finals.values.sorted { ($0["start"] as! Double) < ($1["start"] as! Double) }
                    .map { $0["text"] as! String }.joined()
                guard !text.isEmpty else { throw failure("empty-final-\(job["id"]!)") }
                let elapsed = start.duration(to: .now)
                let record: [String: Any] = ["id": job["id"]!, "dataset": job["dataset"]!, "punctuation": enabled,
                    "text": text, "events": events, "audio_seconds": duration, "audio_path": job["path"]!,
                    "elapsed_ms": Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
                    "recorded_at": ISO8601DateFormatter().string(from: Date())]
                try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                try handle.write(contentsOf: Data([10]))
            }
            if (index + 1).isMultiple(of: 10) || index == jobs.count - 1 { print("Apple audio \(index + 1)/\(jobs.count)") }
        }
    }
    static func failure(_ message: String) -> NSError { NSError(domain: message, code: 1) }
}
