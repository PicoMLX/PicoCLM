import Foundation
import PicoContext

public enum EvaluationPolicy: String, CaseIterable, Codable, Sendable {
    case appendOnly, editable, summarization
    var mode: RunMode { self == .appendOnly ? .appendOnly : .editable }
    var editStyle: ContextEditStyle { self == .summarization ? .summarize : .targeted }
}

public struct EvaluationLimits: Codable, Sendable {
    public var contextWindow: Int
    public var turnTokens: Int
    public var episodeTokens: Int
    public var decisionOutput: Int
    public var completionOutput: Int
    public var decisionAttempts: Int

    public init(contextWindow: Int = 4_096, turnTokens: Int = 24_000, episodeTokens: Int = 80_000,
                decisionOutput: Int = 1_024, completionOutput: Int = 512, decisionAttempts: Int = 4) {
        self.contextWindow = contextWindow; self.turnTokens = turnTokens; self.episodeTokens = episodeTokens
        self.decisionOutput = decisionOutput; self.completionOutput = completionOutput; self.decisionAttempts = decisionAttempts
    }
    var budget: RunBudget {
        RunBudget(contextWindow: contextWindow, totalTokens: turnTokens, editOutputTokens: decisionOutput,
                  completionOutputTokens: completionOutput, maxEditAttempts: decisionAttempts)
    }
    func validate() throws {
        guard (1...32_768).contains(contextWindow), (1...10_000_000).contains(turnTokens),
              (1...10_000_000).contains(episodeTokens), (1...4_096).contains(decisionOutput),
              (1...4_096).contains(completionOutput), (1...4).contains(decisionAttempts) else {
            throw ContextError.invalid("invalid evaluation token limits")
        }
    }
}

public struct EvaluationConfiguration: Codable, Sendable {
    public var scenario: DiagnosticScenario
    public var seeds: [UInt64]
    public var repetitions: Int
    public var stepCount: Int
    public var noiseLines: Int
    public var policies: [EvaluationPolicy]
    public var limits: EvaluationLimits

    public init(scenario: DiagnosticScenario = .retention, seeds: [UInt64] = [17, 29], repetitions: Int = 3,
                stepCount: Int = 4, noiseLines: Int = 12,
                policies: [EvaluationPolicy] = EvaluationPolicy.allCases, limits: EvaluationLimits = EvaluationLimits()) {
        self.scenario = scenario; self.seeds = seeds; self.repetitions = repetitions
        self.stepCount = stepCount; self.noiseLines = noiseLines; self.policies = policies; self.limits = limits
    }

    public func validate() throws {
        guard (1...16).contains(seeds.count), Set(seeds).count == seeds.count,
              (1...4).contains(repetitions), (1...32).contains(stepCount), (0...128).contains(noiseLines),
              !policies.isEmpty, Set(policies).count == policies.count,
              seeds.count * repetitions * policies.count * stepCount <= 128 else {
            throw ContextError.invalid("invalid evaluation configuration or more than 128 planned steps")
        }
        try limits.validate()
    }
}

public struct EvaluationProvenance: Codable, Sendable {
    public let backend: String
    public let model: String
    public let modelRevision: String
    public let sampling: String
    public let sourceRevision: String
    public let swiftVersion: String
    public let operatingSystem: String

    public init(backend: String, model: String, modelRevision: String, sampling: String,
                sourceRevision: String = "unknown", swiftVersion: String = "unknown",
                operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString) {
        self.backend = backend; self.model = model; self.modelRevision = modelRevision; self.sampling = sampling
        self.sourceRevision = sourceRevision; self.swiftVersion = swiftVersion; self.operatingSystem = operatingSystem
    }
}

public struct EvaluationCall: Codable, Sendable {
    public let phase: String
    public let editStyle: ContextEditStyle
    public let context: ContextSnapshot
    public let controlRecords: [ContextRecord]
    public let tokenIDs: [Int]
    public let renderedPrompt: String
    init(_ prompt: PreparedPrompt) {
        phase = prompt.input.phase.rawValue; editStyle = prompt.input.editStyle; context = prompt.input.context; controlRecords = prompt.input.controlRecords
        tokenIDs = prompt.tokenIDs; renderedPrompt = prompt.renderedPrompt
    }
}

public struct EvaluationAttempt: Codable, Sendable {
    public let arguments: String
    public let modelText: String
    public let outcome: String
    public let detail: String
    init(_ attempt: EditAttempt) {
        arguments = attempt.arguments; modelText = attempt.modelText
        outcome = attempt.outcome.rawValue; detail = attempt.detail
    }
}

public struct EvaluationStep: Codable, Sendable {
    public let id: String
    public let incoming: [ContextRecord]
    public let expectedFacts: [String: String]
    public let retainedFacts: [String: String]
    public let retainedCorrect: Bool
    public let answerCorrect: Bool
    public let answer: String?
    public let failure: String?
    public let original: ContextSnapshot?
    public let runStart: ContextSnapshot?
    public let revised: ContextSnapshot?
    public let originalPromptTokens: Int?
    public let originalPromptFailure: String?
    public let runStartPromptTokens: Int?
    public let finalPromptTokens: Int?
    public let inputTokens: Int
    public let generatedTokens: Int
    public let attempts: [EvaluationAttempt]
    public let calls: [EvaluationCall]
    init(_ step: DiagnosticStepReport) {
        id = step.step.id; incoming = step.step.records
        expectedFacts = step.step.expectedFacts; retainedFacts = step.retainedFacts
        retainedCorrect = step.retainedCorrect; answerCorrect = step.answerCorrect
        failure = step.failure; answer = step.run?.answer
        original = step.run?.original; runStart = step.run?.runStart; revised = step.run?.revised
        originalPromptTokens = step.run?.originalPromptTokens; originalPromptFailure = step.run?.originalPromptFailure
        runStartPromptTokens = step.run?.runStartPromptTokens; finalPromptTokens = step.run?.finalPrompt?.tokenCount
        inputTokens = step.run?.totalInputTokens ?? 0; generatedTokens = step.run?.totalGeneratedTokens ?? 0
        attempts = step.run?.attempts.map(EvaluationAttempt.init) ?? []; calls = step.run?.calls.map(EvaluationCall.init) ?? []
    }
}

public struct EvaluationResult: Codable, Sendable {
    public let order: Int
    public let seed: UInt64
    public let repetition: Int
    public let policy: EvaluationPolicy
    public let plannedSteps: Int
    /// Completion-template footprint of initial instructions plus all incoming operations, without answers.
    public let environmentPromptTokens: Int
    public var environmentPromptPressure: Double { Double(environmentPromptTokens) / Double(contextWindow) }
    public let contextWindow: Int
    public let steps: [EvaluationStep]
    public let passed: Bool
    public let failure: String?
    public let inputTokens: Int
    public let generatedTokens: Int
    public let elapsedSeconds: Double
    public let original: ContextSnapshot
    public let revised: ContextSnapshot
    public var retainedCorrectSteps: Int { steps.filter(\.retainedCorrect).count }
    public var answerCorrectSteps: Int { steps.filter(\.answerCorrect).count }
    init(order: Int, seed: UInt64, repetition: Int, policy: EvaluationPolicy, plannedSteps: Int, environmentPromptTokens: Int, contextWindow: Int, report: DiagnosticReport) {
        self.order = order; self.seed = seed; self.repetition = repetition; self.policy = policy
        self.plannedSteps = plannedSteps; self.environmentPromptTokens = environmentPromptTokens; self.contextWindow = contextWindow
        steps = report.steps.map(EvaluationStep.init)
        passed = report.passed; failure = report.failure
        inputTokens = report.totalInputTokens; generatedTokens = report.totalGeneratedTokens
        elapsedSeconds = report.elapsedSeconds; original = report.original; revised = report.revised
    }
}

public struct EvaluationReport: Codable, Sendable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let configuration: EvaluationConfiguration
    public let provenance: EvaluationProvenance
    public let results: [EvaluationResult]

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// Sequential, isolated sessions using identical generated data and cyclic policy order.
public struct EvaluationRunner: Sendable {
    private let runner: DiagnosticRunner
    private let counter: any TokenCounting
    public init(counter: any TokenCounting, backend: any ContextModelBackend) {
        runner = DiagnosticRunner(counter: counter, backend: backend)
        self.counter = counter
    }

    public func run(_ configuration: EvaluationConfiguration, scope: ContextScope,
                    provenance: EvaluationProvenance,
                    onResult: @Sendable (EvaluationResult) async -> Void = { _ in }) async throws -> EvaluationReport {
        try configuration.validate()
        var results: [EvaluationResult] = []
        for (seedIndex, seed) in configuration.seeds.enumerated() {
            let episode = try DiagnosticEpisode.generated(configuration.scenario, scope: scope, seed: seed,
                                                          stepCount: configuration.stepCount, noiseLines: configuration.noiseLines)
            let environment = ContextSnapshot(scope: scope, records: episode.initial.records + episode.steps.flatMap(\.records))
            let environmentTokens = try await counter.prepare(ModelInput(context: environment, phase: .completion)).tokenCount
            for repetition in 0..<configuration.repetitions {
                let start = (seedIndex + repetition) % configuration.policies.count
                for index in configuration.policies.indices {
                    try Task.checkCancellation()
                    let policy = configuration.policies[(start + index) % configuration.policies.count]
                    let report = try await runner.run(episode, mode: policy.mode, budget: configuration.limits.budget,
                                                      episodeTokenLimit: configuration.limits.episodeTokens, editStyle: policy.editStyle)
                    let result = EvaluationResult(order: results.count, seed: seed, repetition: repetition, policy: policy,
                                                  plannedSteps: episode.steps.count, environmentPromptTokens: environmentTokens,
                                                  contextWindow: configuration.limits.contextWindow, report: report)
                    results.append(result)
                    await onResult(result)
                    try Task.checkCancellation()
                }
            }
        }
        return EvaluationReport(schemaVersion: 2, createdAt: Date(), configuration: configuration,
                                provenance: provenance, results: results)
    }
}
