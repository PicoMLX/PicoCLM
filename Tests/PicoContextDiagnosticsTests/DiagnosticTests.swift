import Foundation
import PicoContext
import PicoContextDiagnostics
import Testing

private let scope = ContextScope(userID: "diagnostic-user", conversationID: "stream", branchID: "main")
private let budget = RunBudget(contextWindow: 32_000, totalTokens: 120_000)

private struct DiagnosticCounter: TokenCounting {
    func prepare(_ input: ModelInput) async -> PreparedPrompt {
        let text = input.instructions + (input.context.records + input.controlRecords).map {
            "\($0.id) \($0.role.rawValue) \($0.body)"
        }.joined(separator: "\n")
        return PreparedPrompt(input: input, tokenIDs: text.utf8.map(Int.init), renderedPrompt: text)
    }
}

private actor NotebookBackend: ContextModelBackend {
    private(set) var prompts: [PreparedPrompt] = []
    private let loseNeedle: Bool
    private var forcedAnswers: [[String: String]]

    init(loseNeedle: Bool = false, forcedAnswers: [[String: String]] = []) {
        self.loseNeedle = loseNeedle
        self.forcedAnswers = forcedAnswers
    }

    func generate(_ prompt: PreparedPrompt, maxTokens: Int) throws -> ModelResponse {
        prompts.append(prompt)
        if prompt.input.phase == .edit {
            let operations = prompt.input.context.records.filter { $0.role == .tool }.compactMap { record -> [String: String]? in
                let lines = record.body.components(separatedBy: "\n").filter {
                    ($0.hasPrefix("FACT ") || $0.hasPrefix("REMOVE ")) && !(loseNeedle && $0.contains("amber="))
                }
                let body = lines.joined(separator: "\n")
                guard body != record.body else { return nil }
                return ["action": "replace", "recordID": record.id, "body": body]
            }
            let arguments: [String: Any] = operations.isEmpty ? ["baseRevision": prompt.input.context.revision]
                : ["baseRevision": prompt.input.context.revision, "operations": operations]
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            return ModelResponse(toolCalls: [ModelToolCall(name: operations.isEmpty ? ContextKeepTool.name : ContextEditTool.name,
                                                          arguments: String(decoding: data, as: UTF8.self))], generatedTokens: 8)
        }
        // Independently derive the output from the supplied live notebook, not expected fixture values.
        var state: [String: String] = [:]
        for record in prompt.input.context.records {
            for line in record.body.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                if parts[0] == "FACT" {
                    let entry = parts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if entry.count == 2 { state[String(entry[0])] = String(entry[1]) }
                } else if parts[0] == "REMOVE" { state.removeValue(forKey: String(parts[1])) }
            }
        }
        if !forcedAnswers.isEmpty { state = forcedAnswers.removeFirst() }
        let data = try JSONEncoder().encode(["facts": state])
        return ModelResponse(text: String(decoding: data, as: UTF8.self), generatedTokens: 4)
    }
}

@Test(arguments: DiagnosticScenario.allCases)
func fixtureInstructionsDescribeOperationsWithoutAddingNotebookEntries(scenario: DiagnosticScenario) throws {
    let episode = try DiagnosticEpisode.fixture(scenario, scope: scope)
    #expect(DiagnosticGrading.retainedState(in: episode.initial).isEmpty)
}

@Test(arguments: DiagnosticScenario.allCases, [RunMode.appendOnly, .editable])
func sequentialEpisodesDeliverOperationsAndCallerRepliesIntoExactNextInput(scenario: DiagnosticScenario, mode: RunMode) async throws {
    let episode = try DiagnosticEpisode.fixture(scenario, scope: scope, noiseLines: 3)
    let backend = NotebookBackend()
    let report = try await DiagnosticRunner(counter: DiagnosticCounter(), backend: backend).run(episode, mode: mode, budget: budget, episodeTokenLimit: 120_000)
    #expect(report.passed)
    #expect(report.steps.count == 4)
    #expect(report.steps.allSatisfy { $0.retainedFacts == $0.step.expectedFacts })
    let prompts = await backend.prompts
    let completions = prompts.filter { $0.input.phase == .completion }
    #expect(completions.count == 4)
    for index in episode.steps.indices {
        let step = episode.steps[index]
        let prompt = completions[index]
        #expect(prompt.input.context.records.contains { $0.id == "\(step.id)-data" })
        #expect(prompt.input.context.records.last?.id == "\(step.id)-request")
        if index > 0 { #expect(prompt.input.context.records.contains { $0.id == episode.steps[index - 1].answerRecordID }) }
        let run = try #require(report.steps[index].run)
        #expect(prompt.tokenIDs == run.finalPrompt?.tokenIDs)
        #expect(prompt.input.context == run.revised)
        try WorkingContext.validate(ContextSnapshot(scope: scope, revision: run.revised.revision,
                                                   records: prompt.input.context.records + prompt.input.controlRecords))
        #expect(report.original.records.contains { $0.id == step.answerRecordID })
    }
    #expect(report.totalInputTokens == prompts.reduce(0) { $0 + $1.tokenCount })
    #expect(report.totalGeneratedTokens == prompts.count * 4 + prompts.filter { $0.input.phase == .edit }.count * 4)
    #expect(report.original.records.filter { $0.role == .tool }.allSatisfy { $0.body.contains("Telemetry") })
    if mode == .editable {
        #expect(report.revised.records.filter { $0.role == .tool }.allSatisfy { !$0.body.contains("Telemetry") })
    }
    #expect(report.revised.records.last?.id == episode.steps.last?.answerRecordID)
}

@Test func correctScriptedAnswersCannotHideLostLiveContext() async throws {
    let episode = try DiagnosticEpisode.fixture(.retention, scope: scope, noiseLines: 2)
    let backend = NotebookBackend(loseNeedle: true, forcedAnswers: episode.steps.map(\.expectedFacts))
    let report = try await DiagnosticRunner(counter: DiagnosticCounter(), backend: backend).run(episode, mode: .editable, budget: budget, episodeTokenLimit: 120_000)
    #expect(report.failure == nil)
    #expect(report.steps.allSatisfy { $0.answerCorrect })
    #expect(report.steps.first?.retainedCorrect == false)
    // Later appended answers legitimately restore literal values to live history.
    #expect(report.steps.dropFirst().allSatisfy { $0.retainedCorrect })
    #expect(!report.passed)
    #expect(!DiagnosticGrading.retainedState(in: report.revised).keys.contains("amber"))
    #expect(report.original.records.contains { $0.body.contains("FACT amber=TQ-4819-X") })
}

@Test(arguments: ["Notes: FACT amber=TQ-4819-X; FACT beryl=M8:blue/42", "{\"facts\":{\"amber\":\"TQ-4819-X\",\"beryl\":\"M8:blue/42\"}}",
                  "FACT amber=TQ-4819-XX; FACT beryl=M8:blue/420"])
func literalRetentionDoesNotDependOnNoteStyleOrCreditExtendedIdentifiers(body: String) {
    let snapshot = ContextSnapshot(scope: scope, records: [ContextRecord(id: "note", role: .assistant, body: body)])
    let expected = ["amber": "TQ-4819-X", "beryl": "M8:blue/42"]
    let retained = DiagnosticGrading.retainedFacts(in: snapshot, expected: expected, check: .exactValues)
    #expect(retained == (body.contains("TQ-4819-XX") ? [:] : expected))
}

@Test func updatesAndRemovalsAreGradedInLiveOrder() throws {
    let episode = try DiagnosticEpisode.fixture(.stateUpdates, scope: scope, noiseLines: 0)
    var working = try WorkingContext(episode.initial)
    for step in episode.steps {
        try working.append(ContextAppend(scope: scope, baseRevision: working.snapshot.revision, records: step.records))
        #expect(DiagnosticGrading.retainedState(in: working.snapshot) == step.expectedFacts)
    }
    #expect(DiagnosticGrading.retainedState(in: working.snapshot) == ["units": "3", "owner": "Jo"])
}

@Test func boundedPressureReportsFailureWithoutTruncationAndEditingCanContinue() async throws {
    let episode = try DiagnosticEpisode.fixture(.retention, scope: scope, noiseLines: 50)
    let pressureBudget = RunBudget(contextWindow: 12_000, totalTokens: 120_000)
    let runner = DiagnosticRunner(counter: DiagnosticCounter(), backend: NotebookBackend())
    let baseline = try await runner.run(episode, mode: .appendOnly, budget: pressureBudget, episodeTokenLimit: 120_000)
    let editable = try await runner.run(episode, mode: .editable, budget: pressureBudget, episodeTokenLimit: 120_000)
    #expect(baseline.failure?.contains("context window") == true)
    #expect(baseline.steps.count < episode.steps.count)
    let last = try #require(baseline.steps.last)
    #expect(baseline.revised.records.contains { $0 == last.step.records[1] })
    #expect(last.run?.calls.isEmpty == true)
    #expect(editable.passed)
    #expect(editable.steps.count == 4)
}

@Test func wholeEpisodeAllowanceCountsAllCallsAndStopsBeforeAnotherGeneration() async throws {
    let episode = try DiagnosticEpisode.fixture(.retention, scope: scope, noiseLines: 0)
    let first = ContextSnapshot(scope: scope, revision: 1, records: episode.initial.records + episode.steps[0].records)
    let tokens = await DiagnosticCounter().prepare(ModelInput(context: first, phase: .completion)).tokenCount
    let limit = tokens + budget.completionOutputTokens + 5
    let backend = NotebookBackend()
    let report = try await DiagnosticRunner(counter: DiagnosticCounter(), backend: backend).run(episode, mode: .appendOnly, budget: budget, episodeTokenLimit: limit)
    #expect(report.failure?.contains("budget exceeded") == true)
    #expect(report.steps.count == 2)
    #expect(report.totalInputTokens + report.totalGeneratedTokens <= limit)
    #expect(await backend.prompts.count == 1)
    #expect(report.steps.last?.run?.calls.isEmpty == true)
}

@Test(arguments: [
    "{\"facts\":{\"units\":\"3\",\"owner\":\"Jo\"}}",
    "{\"facts\":{\"units\":3,\"owner\":\"Jo\"}}",
    "{\"facts\":{\"units\":\"13\",\"owner\":\"Jo\"}}",
    "{\"facts\":{\"units\":\"3\",\"owner\":\"Jo\",\"rack\":\"A4\"}}",
    "{\"facts\":{\"units\":\"3\"}}",
    "{\"facts\":{\"units\":\"3\",\"owner\":\"Jo\"},\"extra\":true}",
    "The answer is units 3 and owner Jo."
])
func structuredAnswersRequireExactState(json: String) {
    #expect(DiagnosticGrading.answerMatches(json, expected: ["units": "3", "owner": "Jo"]) == (json == "{\"facts\":{\"units\":\"3\",\"owner\":\"Jo\"}}"))
}
