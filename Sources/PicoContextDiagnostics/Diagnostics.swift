import Foundation
import PicoContext

public enum DiagnosticScenario: String, CaseIterable, Sendable {
    case retention, stateUpdates

    public var title: String {
        switch self {
        case .retention: "Exact retention"
        case .stateUpdates: "State updates"
        }
    }
}

public enum DiagnosticContextCheck: String, Sendable {
    /// Literal value survival anywhere in live bodies, independently of note formatting.
    case exactValues
    /// Execute the fixture's line-based FACT/REMOVE protocol in live record order.
    case notebookState
}

public struct DiagnosticStep: Sendable {
    public let id: String
    public let records: [ContextRecord]
    public let answerRecordID: String
    public let expectedFacts: [String: String]

    public init(id: String, records: [ContextRecord], answerRecordID: String, expectedFacts: [String: String]) {
        self.id = id
        self.records = records
        self.answerRecordID = answerRecordID
        self.expectedFacts = expectedFacts
    }
}

public struct DiagnosticEpisode: Sendable {
    public let title: String
    public let initial: ContextSnapshot
    public let steps: [DiagnosticStep]
    public let contextCheck: DiagnosticContextCheck

    public init(title: String, initial: ContextSnapshot, steps: [DiagnosticStep], contextCheck: DiagnosticContextCheck = .notebookState) {
        self.title = title
        self.initial = initial
        self.steps = steps
        self.contextCheck = contextCheck
    }

    /// Original fixed instances, inspired by streamed retention/state diagnostics, not ContextBench tasks.
    public static func fixture(_ scenario: DiagnosticScenario, scope: ContextScope, noiseLines: Int = 12) throws -> Self {
        guard (0...128).contains(noiseLines) else { throw ContextError.invalid("noiseLines must be 0...128") }
        let initial = ContextSnapshot(scope: scope, records: [
            ContextRecord(id: "instructions", role: .system, body: """
            Maintain an exact notebook through a sequence of updates supplied in tool results.
            A line of the form FACT key=value assigns a string value; newer assignments replace older values.
            A line of the form REMOVE key deletes that key. Telemetry is irrelevant.
            During context editing, preserve the complete current notebook as separate exact FACT key=value lines.
            Keep each FACT or REMOVE operation on its own line. Never join operations with semicolons.
            When shortening a tool result, copy its operation lines exactly and remove only telemetry.
            Keep deletions effective; do not let an older assignment resurrect a removed key.
            During the context decision phase, call one of the offered context tools instead of answering.
            During the completion phase, answer the latest user request with only a JSON object containing facts, a dictionary of string values.
            Return every current key with its exact value, no removed keys, explanations or Markdown fences.
            Every JSON value must be a quoted string, even numeric text. Do not output JSON numbers.
            """),
            ContextRecord(id: "task", role: .user, body: "Process each incoming notebook update and report the complete current notebook.", isProtected: true)
        ])
        let operations: [[String]]
        let expected: [[String: String]]
        switch scenario {
        case .retention:
            operations = [["FACT amber=TQ-4819-X"], ["FACT beryl=M8:blue/42"], [], ["FACT coral=invoice-0097"]]
            expected = [["amber": "TQ-4819-X"], ["amber": "TQ-4819-X", "beryl": "M8:blue/42"],
                        ["amber": "TQ-4819-X", "beryl": "M8:blue/42"],
                        ["amber": "TQ-4819-X", "beryl": "M8:blue/42", "coral": "invoice-0097"]]
        case .stateUpdates:
            operations = [["FACT rack=A4", "FACT units=7"], ["FACT units=11", "FACT owner=Mina"],
                          ["REMOVE rack", "FACT owner=Jo"], ["FACT units=3"]]
            expected = [["rack": "A4", "units": "7"], ["rack": "A4", "units": "11", "owner": "Mina"],
                        ["units": "11", "owner": "Jo"], ["units": "3", "owner": "Jo"]]
        }
        let steps = try operations.indices.map { index in
            let id = "step-\(index + 1)"
            let placeholders = Dictionary(uniqueKeysWithValues: expected[index].keys.map { ($0, "<value from notebook>") })
            let shape = String(decoding: try JSONSerialization.data(withJSONObject: ["facts": placeholders], options: [.sortedKeys]), as: UTF8.self)
            let noise = (0..<noiseLines).map { line in
                "Telemetry batch \(index + 1), tick \(line): probe ready; routing sample discarded; no notebook change."
            }
            let records = [
                ContextRecord(id: "\(id)-call", role: .assistant, body: "", toolCalls: [
                    ContextToolCall(id: "\(id)-input", name: "notebook_input", arguments: "{\"step\":\(index + 1)}")
                ]),
                ContextRecord(id: "\(id)-data", role: .tool, body: (operations[index] + noise).joined(separator: "\n"), toolCallID: "\(id)-input"),
                ContextRecord(id: "\(id)-request", role: .user,
                              body: "Report the complete current notebook. Return only this JSON shape, replacing placeholders with exact values from the notebook: \(shape). The facts field must be an object, not a string. Quote every value, including numeric text. No FACT lines, record headers or Markdown in the answer.",
                              isProtected: true)
            ]
            return DiagnosticStep(id: id, records: records, answerRecordID: "\(id)-answer", expectedFacts: expected[index])
        }
        return Self(title: scenario.title, initial: initial, steps: steps,
                    contextCheck: scenario == .retention ? .exactValues : .notebookState)
    }
}

public enum DiagnosticGrading {
    /// Fold exact notebook operation lines in live record order.
    public static func retainedState(in context: ContextSnapshot) -> [String: String] {
        var state: [String: String] = [:]
        for line in context.records.flatMap({ $0.body.components(separatedBy: .newlines) }) {
            if line.hasPrefix("FACT "), let separator = line.firstIndex(of: "=") {
                let key = String(line[line.index(line.startIndex, offsetBy: 5)..<separator])
                if !key.isEmpty { state[key] = String(line[line.index(after: separator)...]) }
            } else if line.hasPrefix("REMOVE ") {
                state.removeValue(forKey: String(line.dropFirst(7)))
            }
        }
        return state
    }

    public static func retainedFacts(in context: ContextSnapshot, expected: [String: String],
                                     check: DiagnosticContextCheck) -> [String: String] {
        switch check {
        case .notebookState: return retainedState(in: context)
        case .exactValues:
            // Check before this turn's answer appends. Earlier caller-appended answers are live history.
            return expected.filter { _, value in
                guard !value.isEmpty else { return false }
                let pattern = "(?<![\\p{L}\\p{N}_:/-])" + NSRegularExpression.escapedPattern(for: value) + "(?![\\p{L}\\p{N}_:/-])"
                return context.records.contains { $0.body.range(of: pattern, options: .regularExpression) != nil }
            }
        }
    }

    public static func answerMatches(_ answer: String, expected: [String: String]) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any],
              Set(object.keys) == ["facts"], let facts = object["facts"] as? [String: String] else { return false }
        return facts == expected
    }
}

public struct DiagnosticStepReport: Sendable {
    public let step: DiagnosticStep
    public let run: RunReport?
    public let retainedFacts: [String: String]
    public let retainedCorrect: Bool
    public let answerCorrect: Bool
    public let failure: String?
}

public struct DiagnosticReport: Sendable {
    public let title: String
    public let mode: RunMode
    public let steps: [DiagnosticStepReport]
    public let original: ContextSnapshot
    public let revised: ContextSnapshot
    public let failure: String?
    public let elapsedSeconds: Double
    public var passed: Bool { failure == nil && !steps.isEmpty && steps.allSatisfy { $0.retainedCorrect && $0.answerCorrect } }
    public var totalInputTokens: Int { steps.reduce(0) { $0 + ($1.run?.totalInputTokens ?? 0) } }
    public var totalGeneratedTokens: Int { steps.reduce(0) { $0 + ($1.run?.totalGeneratedTokens ?? 0) } }
}

/// Runs one continuous session, delivering each operation before its model call.
/// Benchmark-specific fixtures/grading stay outside PicoContext's runtime.
public struct DiagnosticRunner: Sendable {
    private let counter: any TokenCounting
    private let backend: any ContextModelBackend

    public init(counter: any TokenCounting, backend: any ContextModelBackend) {
        self.counter = counter
        self.backend = backend
    }

    public func run(_ episode: DiagnosticEpisode, mode: RunMode, budget: RunBudget = RunBudget(),
                    episodeTokenLimit: Int = 80_000,
                    onStep: @Sendable (DiagnosticStepReport) async -> Void = { _ in }) async throws -> DiagnosticReport {
        guard (1...32).contains(episode.steps.count),
              Set(episode.steps.map(\.id)).count == episode.steps.count,
              episode.steps.allSatisfy({ !$0.id.isEmpty }),
              (1...10_000_000).contains(episodeTokenLimit) else { throw ContextError.invalid("invalid diagnostic episode bounds") }
        let start = Date()
        let session = try ContextSession(context: episode.initial, counter: counter, backend: backend)
        var reports: [DiagnosticStepReport] = []
        var failure: String?
        var used = 0
        for step in episode.steps {
            try Task.checkCancellation()
            var run: RunReport?
            do {
                guard used < episodeTokenLimit else { throw ContextError.budgetExceeded("episode token allowance exhausted") }
                let current = await session.context
                try await session.append(ContextAppend(scope: current.scope, baseRevision: current.revision, records: step.records))
                let stepBudget = RunBudget(contextWindow: budget.contextWindow, totalTokens: min(budget.totalTokens, episodeTokenLimit - used),
                                           editOutputTokens: budget.editOutputTokens, completionOutputTokens: budget.completionOutputTokens,
                                           maxEditAttempts: budget.maxEditAttempts)
                let result = try await session.run(mode: mode, budget: stepBudget)
                run = result
                used += result.totalInputTokens + result.totalGeneratedTokens
                let retained = DiagnosticGrading.retainedFacts(in: result.revised, expected: step.expectedFacts, check: episode.contextCheck)
                reports.append(DiagnosticStepReport(step: step, run: result, retainedFacts: retained,
                                                    retainedCorrect: retained == step.expectedFacts,
                                                    answerCorrect: result.failure == nil && DiagnosticGrading.answerMatches(result.answer, expected: step.expectedFacts),
                                                    failure: result.failure))
                if let latest = reports.last { await onStep(latest) }
                if let error = result.failure { failure = error; break }
                // Runtime/caller chooses the record identity; the model only supplied its body.
                try await session.append(ContextAppend(scope: result.revised.scope, baseRevision: result.revised.revision,
                                                       records: [ContextRecord(id: step.answerRecordID, role: .assistant, body: result.answer)]))
            } catch is CancellationError { throw CancellationError() }
            catch {
                failure = error.localizedDescription
                if run == nil {
                    reports.append(DiagnosticStepReport(step: step, run: nil, retainedFacts: [:], retainedCorrect: false,
                                                        answerCorrect: false, failure: failure))
                }
                break
            }
        }
        return DiagnosticReport(title: episode.title, mode: mode, steps: reports, original: await session.originalContext,
                                revised: await session.context, failure: failure, elapsedSeconds: Date().timeIntervalSince(start))
    }
}
