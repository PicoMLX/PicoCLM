import Foundation
import PicoContext

extension DiagnosticEpisode {
    /// Original seeded instances. The seed identifies task data, not stochastic model sampling.
    public static func generated(_ scenario: DiagnosticScenario, scope: ContextScope, seed: UInt64,
                                 stepCount: Int = 4, noiseLines: Int = 12) throws -> Self {
        guard (1...32).contains(stepCount), (0...128).contains(noiseLines) else {
            throw ContextError.invalid("generated episode needs 1...32 steps and 0...128 noise lines")
        }
        let initial = try fixture(scenario, scope: scope, noiseLines: 0).initial
        var random = EpisodeRandom(seed: seed)
        var noiseRandom = EpisodeRandom(seed: seed ^ 0xd1b54a32d192ed03)
        var state: [String: String] = [:]
        var steps: [DiagnosticStep] = []
        for index in 0..<stepCount {
            let key = "slot\(index % 8)"
            var lines: [String] = []
            if scenario == .stateUpdates && index % 5 == 4 {
                state.removeValue(forKey: key)
                lines.append("REMOVE \(key)")
                let previous = "slot\((index - 1) % 8)"
                state.removeValue(forKey: previous)
                lines.append("REMOVE \(previous)")
            } else if scenario == .stateUpdates || index < 8 {
                let value = "v-\(String(random.next(), radix: 16))"
                state[key] = value
                lines.append("FACT \(key)=\(value)")
            }
            let noise = (0..<noiseLines).map { line in
                "Telemetry batch \(index + 1), tick \(line): sample \(String(noiseRandom.next(), radix: 16)); no notebook change."
            }
            let id = "step-\(index + 1)"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let shape = String(decoding: try encoder.encode(["facts": state.mapValues { _ in "<value from notebook>" }]), as: UTF8.self)
            let records = [
                ContextRecord(id: "\(id)-call", role: .assistant, body: "", toolCalls: [
                    ContextToolCall(id: "\(id)-input", name: "notebook_input", arguments: "{\"step\":\(index + 1)}")
                ]),
                ContextRecord(id: "\(id)-data", role: .tool, body: (lines + noise).joined(separator: "\n"), toolCallID: "\(id)-input"),
                ContextRecord(id: "\(id)-request", role: .user,
                              body: "Report the complete current notebook as this JSON shape with exact quoted string values: \(shape). No extra text, Markdown or record headers.",
                              isProtected: true)
            ]
            steps.append(DiagnosticStep(id: id, records: records, answerRecordID: "\(id)-answer", expectedFacts: state))
        }
        let episode = Self(title: "\(scenario.title), seed \(seed)", initial: initial, steps: steps,
                           contextCheck: scenario == .retention ? .exactValues : .notebookState)
        // Validate each arrival transaction and oracle state before any model call.
        var working = try WorkingContext(initial)
        for step in steps {
            try working.append(ContextAppend(scope: scope, baseRevision: working.snapshot.revision, records: step.records))
            guard DiagnosticGrading.retainedState(in: working.snapshot) == step.expectedFacts else {
                throw ContextError.invalid("generated notebook oracle disagrees with operation stream")
            }
        }
        return episode
    }
}

/// SplitMix64 arithmetic provides stable task instances across Swift processes/platforms.
private struct EpisodeRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
