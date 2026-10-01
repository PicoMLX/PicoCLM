import Foundation
import PicoContext
import PicoContextDiagnostics
import Testing

private let evaluationScope = ContextScope(userID: "caller", conversationID: "evaluation", branchID: "branch")
private let provenance = EvaluationProvenance(backend: "test", model: "notebook", modelRevision: "1", sampling: "deterministic")
private let byteLimits = EvaluationLimits(contextWindow: 32_768, turnTokens: 500_000, episodeTokens: 2_000_000)

private actor EvaluationSpy: ContextModelBackend {
    private(set) var prompts: [PreparedPrompt] = []
    func generate(_ prompt: PreparedPrompt, maxTokens: Int) async throws -> ModelResponse {
        prompts.append(prompt)
        return try await DeterministicNotebookBackend().generate(prompt, maxTokens: maxTokens)
    }
}

@Test(arguments: DiagnosticScenario.allCases)
func seededStreamsAreStableAndPressureDoesNotChangeTaskFacts(scenario: DiagnosticScenario) throws {
    let first = try DiagnosticEpisode.generated(scenario, scope: evaluationScope, seed: 17, stepCount: 12, noiseLines: 1)
    let repeatEpisode = try DiagnosticEpisode.generated(scenario, scope: evaluationScope, seed: 17, stepCount: 12, noiseLines: 1)
    let pressure = try DiagnosticEpisode.generated(scenario, scope: evaluationScope, seed: 17, stepCount: 12, noiseLines: 64)
    let other = try DiagnosticEpisode.generated(scenario, scope: evaluationScope, seed: 29, stepCount: 12, noiseLines: 1)
    #expect(first.steps.map(\.records) == repeatEpisode.steps.map(\.records))
    #expect(first.steps.map(\.expectedFacts) == pressure.steps.map(\.expectedFacts))
    #expect(first.steps.map(\.expectedFacts) != other.steps.map(\.expectedFacts))
    #expect(first.initial.scope == evaluationScope)
    if scenario == .stateUpdates {
        #expect(first.steps[4].expectedFacts["slot3"] == nil)
        #expect(first.steps[8].expectedFacts["slot0"] != first.steps[0].expectedFacts["slot0"])
    }
}

@Test(arguments: DiagnosticScenario.allCases)
func batchBalancesOrderAndExportsActualCallsAndContexts(scenario: DiagnosticScenario) async throws {
    let backend = EvaluationSpy()
    let configuration = EvaluationConfiguration(scenario: scenario, seeds: [17, 29], repetitions: 2,
                                                 stepCount: 5, noiseLines: 2, policies: [.appendOnly, .editable], limits: byteLimits)
    let report = try await EvaluationRunner(counter: DiagnosticByteCounter(), backend: backend).run(
        configuration, scope: evaluationScope, provenance: provenance)
    #expect(report.results.map(\.policy) == [.appendOnly, .editable, .editable, .appendOnly, .editable, .appendOnly, .appendOnly, .editable])
    #expect(report.results.allSatisfy { $0.passed })
    let calls = await backend.prompts
    #expect(report.results.reduce(0) { $0 + $1.inputTokens } == calls.reduce(0) { $0 + $1.tokenCount })
    #expect(report.results.flatMap(\.steps).flatMap(\.calls).map(\.tokenIDs) == calls.map(\.tokenIDs))
    for pair in stride(from: 0, to: report.results.count, by: 2) {
        let a = report.results[pair], b = report.results[pair + 1]
        #expect(a.steps.map(\.incoming) == b.steps.map(\.incoming))
        #expect(a.steps.map(\.expectedFacts) == b.steps.map(\.expectedFacts))
        #expect(a.environmentPromptTokens == b.environmentPromptTokens)
    }
    #expect(report.results.allSatisfy { $0.original.scope == evaluationScope && $0.revised.scope == evaluationScope })
    #expect(report.results.allSatisfy { $0.original.records.contains { $0.body.contains("Telemetry") } })
    #expect(report.results.filter { $0.policy == .editable }.allSatisfy { !$0.revised.records.contains { $0.role == .tool && $0.body.contains("Telemetry") } })
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(EvaluationReport.self, from: report.json())
    #expect(decoded.provenance.model == "notebook")
    #expect(decoded.results.map(\.steps).flatMap { $0 }.flatMap(\.calls).map(\.tokenIDs) == calls.map(\.tokenIDs))
    #expect(decoded.results.map(\.original) == report.results.map(\.original))
}

@Test func budgetFailurePreservesIncomingRecordsAndContinuesOtherPolicy() async throws {
    let episode = try DiagnosticEpisode.generated(.retention, scope: evaluationScope, seed: 17, stepCount: 1, noiseLines: 0)
    let context = ContextSnapshot(scope: evaluationScope, records: episode.initial.records + episode.steps[0].records)
    let completionTokens = try await DiagnosticByteCounter().prepare(ModelInput(context: context, phase: .completion)).tokenCount
    let configuration = EvaluationConfiguration(seeds: [17], repetitions: 1, stepCount: 1, noiseLines: 0,
        limits: EvaluationLimits(contextWindow: completionTokens + 512, turnTokens: 100_000, episodeTokens: 100_000))
    let backend = EvaluationSpy()
    let report = try await EvaluationRunner(counter: DiagnosticByteCounter(), backend: backend).run(
        configuration, scope: evaluationScope, provenance: provenance)
    #expect(report.results[0].passed)
    #expect(!report.results[1].passed)
    #expect(report.results[1].failure?.contains("context window") == true)
    #expect(report.results[1].inputTokens == 0)
    #expect(report.results[1].revised.records.suffix(3) == episode.steps[0].records[...])
    #expect(await backend.prompts.count == 1)
}

@Test(arguments: [0, -1, Int.max])
func batchRejectsInvalidBoundsBeforeCallingBackend(stepCount: Int) async throws {
    let backend = EvaluationSpy()
    let configuration = EvaluationConfiguration(stepCount: stepCount, limits: byteLimits)
    await #expect(throws: ContextError.self) {
        try await EvaluationRunner(counter: DiagnosticByteCounter(), backend: backend).run(
            configuration, scope: evaluationScope, provenance: provenance)
    }
    #expect(await backend.prompts.isEmpty)
}

@Test func batchRejectsDuplicateSeedsPoliciesAndOversizedPlan() throws {
    #expect(throws: ContextError.self) { try EvaluationConfiguration(seeds: [17, 17]).validate() }
    #expect(throws: ContextError.self) { try EvaluationConfiguration(policies: [.editable, .editable]).validate() }
    #expect(throws: ContextError.self) { try EvaluationConfiguration(seeds: [1, 2, 3], repetitions: 4, stepCount: 32).validate() }
}

@Test func summarizationConsolidatesHistoryAndChargesEveryDecision() async throws {
    let configuration = EvaluationConfiguration(scenario: .stateUpdates, seeds: [17], repetitions: 3,
                                                 stepCount: 10, noiseLines: 4, limits: byteLimits)
    let backend = EvaluationSpy()
    let report = try await EvaluationRunner(counter: DiagnosticByteCounter(), backend: backend).run(
        configuration, scope: evaluationScope, provenance: provenance)
    #expect(report.results.map(\.policy) == [.appendOnly, .editable, .summarization,
                                             .editable, .summarization, .appendOnly,
                                             .summarization, .appendOnly, .editable])
    #expect(report.results.allSatisfy { $0.passed })
    for result in report.results.filter({ $0.policy == .summarization }) {
        #expect(result.steps.flatMap(\.calls).filter { $0.phase == "edit" }.count == 10)
        #expect(result.steps.flatMap(\.calls).allSatisfy { $0.editStyle == .summarize })
        #expect(result.inputTokens == result.steps.flatMap(\.calls).reduce(0) { $0 + $1.tokenIDs.count })
        #expect(result.generatedTokens > 0)
        for step in result.steps {
            let completion = try #require(step.calls.first { $0.phase == "completion" })
            // Previous answers remain in the immutable transcript, but must not carry
            // obsolete notebook state into the next summarized completion.
            let original = try #require(step.original)
            let priorAnswers = original.records.filter { $0.id.hasSuffix("-answer") }
            for answer in priorAnswers {
                #expect(!answer.body.isEmpty)
                #expect(completion.context.records.first { $0.id == answer.id }?.body.isEmpty == true)
            }
            #expect(completion.context.records.filter { !$0.isProtected && !$0.body.isEmpty }.count == 1)
        }
        #expect(result.revised.records.filter { $0.role == .tool && !$0.body.isEmpty }.count == 1)
        let originalProtected = result.original.records.filter(\.isProtected)
        #expect(result.revised.records.filter(\.isProtected) == originalProtected)
        let originalMetadata = result.original.records.map { [$0.id, $0.role.rawValue, $0.toolCallID ?? "", $0.toolCalls.map(\.id).joined(separator: ",")] }
        let revisedMetadata = result.revised.records.map { [$0.id, $0.role.rawValue, $0.toolCallID ?? "", $0.toolCalls.map(\.id).joined(separator: ",")] }
        #expect(originalMetadata == revisedMetadata)
        try WorkingContext.validate(result.revised)
    }
    let targeted = try #require(report.results.first { $0.policy == .editable })
    let summary = try #require(report.results.first { $0.policy == .summarization })
    #expect(summary.steps.map(\.incoming) == targeted.steps.map(\.incoming))
    #expect(summary.revised.records.filter { $0.role == .tool }.map(\.body) != targeted.revised.records.filter { $0.role == .tool }.map(\.body))
}

@Test func summarizationConsolidatesUserAndAssistantBodiesWithoutChangingToolRelationships() async throws {
    let initial = ContextSnapshot(scope: evaluationScope, records: [
        ContextRecord(id: "task", role: .user, body: "Report the current notebook.", isProtected: true),
        ContextRecord(id: "user-notes", role: .user, body: "FACT owner=old\nFACT obsolete=yes"),
        ContextRecord(id: "old-answer", role: .assistant, body: #"{"facts":{"owner":"old","obsolete":"yes"}}"#),
        ContextRecord(id: "call", role: .assistant, body: "Reading the next update.", toolCalls: [
            ContextToolCall(id: "input", name: "notebook_input", arguments: "{}")
        ]),
        ContextRecord(id: "data", role: .tool, body: "FACT owner=updated\nTelemetry discarded.", toolCallID: "input"),
        ContextRecord(id: "user-update", role: .user, body: "REMOVE obsolete\nFACT units=3"),
        ContextRecord(id: "request", role: .user, body: "Return the complete notebook.", isProtected: true)
    ])
    let backend = EvaluationSpy()
    let session = try ContextSession(context: initial, counter: DiagnosticByteCounter(), backend: backend)
    let run = try await session.run(budget: RunBudget(contextWindow: 32_768, totalTokens: 100_000), editStyle: .summarize)
    #expect(run.failure == nil)
    #expect(DiagnosticGrading.answerMatches(run.answer, expected: ["owner": "updated", "units": "3"]))
    #expect(run.original == initial)
    #expect(run.revised.scope == initial.scope)
    #expect(run.revised.records.filter(\.isProtected) == initial.records.filter(\.isProtected))
    let expected = initial.records.map { record in
        ContextRecord(id: record.id, role: record.role,
                      body: record.isProtected ? record.body : (record.id == "user-update" ? "FACT owner=updated\nFACT units=3" : ""),
                      isProtected: record.isProtected, toolCalls: record.toolCalls, toolCallID: record.toolCallID)
    }
    #expect(run.revised.records == expected)
    try WorkingContext.validate(run.revised)
    let completion = try #require(await backend.prompts.first { $0.input.phase == .completion })
    #expect(completion.input.context == run.revised)
    #expect(!completion.input.context.records.contains { $0.body.contains("obsolete") || $0.body.contains(#""owner":"old""#) })
}

@Test(arguments: [32, 33])
func summarizationKeepsHistoryWhenFullConsolidationExceedsOperationLimit(recordCount: Int) async throws {
    let records = [ContextRecord(id: "task", role: .user, body: "Keep the current notebook.", isProtected: true)]
        + (0..<recordCount).map { index in
            ContextRecord(id: "history-\(index)", role: .assistant, body: index == 0 ? "FACT owner=Jo" : "Previous answer \(index)")
        }
    let initial = ContextSnapshot(scope: evaluationScope, records: records)
    let session = try ContextSession(context: initial, counter: DiagnosticByteCounter(), backend: DeterministicNotebookBackend())
    let run = try await session.run(budget: RunBudget(contextWindow: 32_768, totalTokens: 100_000, editOutputTokens: 4_096),
                                   editStyle: .summarize)
    #expect(run.failure == nil)
    #expect(DiagnosticGrading.answerMatches(run.answer, expected: ["owner": "Jo"]))
    #expect(run.original == initial)
    if recordCount == 32 {
        #expect(run.revised.records.filter { !$0.isProtected && !$0.body.isEmpty }.count == 1)
        #expect(run.revised.records.last?.body == "FACT owner=Jo")
        #expect(run.revised.revision == initial.revision + 1)
    } else {
        #expect(run.revised == initial)
    }
}
