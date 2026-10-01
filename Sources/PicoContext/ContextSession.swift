import Foundation

public struct RunBudget: Sendable {
    public let contextWindow: Int
    public let totalTokens: Int
    public let editOutputTokens: Int
    public let completionOutputTokens: Int
    public let maxEditAttempts: Int

    public init(contextWindow: Int = 8_192, totalTokens: Int = 24_000,
                editOutputTokens: Int = 1_024, completionOutputTokens: Int = 512,
                maxEditAttempts: Int = 2) {
        self.contextWindow = contextWindow
        self.totalTokens = totalTokens
        self.editOutputTokens = editOutputTokens
        self.completionOutputTokens = completionOutputTokens
        self.maxEditAttempts = maxEditAttempts
    }
}

public enum RunMode: String, Sendable { case appendOnly, editable }

public struct EditAttempt: Sendable {
    public let arguments: String
    public let modelText: String
    public let accepted: Bool
    public let detail: String
}

public struct RunReport: Sendable {
    public let mode: RunMode
    /// The immutable transcript supplied when the session was created.
    public let original: ContextSnapshot
    /// The working revision at the start of this run, including earlier committed edits.
    public let runStart: ContextSnapshot
    public let revised: ContextSnapshot
    /// Nil when the counter cannot render the preserved historical transcript.
    public let originalPromptTokens: Int?
    public let originalPromptFailure: String?
    public let runStartPromptTokens: Int
    public let finalPrompt: PreparedPrompt?
    public let calls: [PreparedPrompt]
    public let attempts: [EditAttempt]
    public let answer: String
    public let failure: String?
    public let totalInputTokens: Int
    public let totalGeneratedTokens: Int
    public let editCallCount: Int
    public let elapsedSeconds: Double

    public var diff: String {
        original.records.compactMap { before in
            guard let after = revised.records.first(where: { $0.id == before.id }) else {
                return "Deleted \(before.id) (\(before.role.rawValue))\n− \(before.body)"
            }
            guard after.body != before.body else { return nil }
            return "Replaced \(before.id) (\(before.role.rawValue))\n− \(before.body)\n+ \(after.body)"
        }.joined(separator: "\n\n")
    }
}

/// One isolated session per caller-owned branch. Reentrant mutations are rejected while running.
public actor ContextSession {
    private var working: WorkingContext
    private let counter: any TokenCounting
    private let backend: any ContextModelBackend
    private let persistence: (any ContextPersistence)?
    private var busy = false

    public init(context: ContextSnapshot, counter: any TokenCounting, backend: any ContextModelBackend,
                persistence: (any ContextPersistence)? = nil) throws {
        working = try WorkingContext(context)
        self.counter = counter
        self.backend = backend
        self.persistence = persistence
    }

    public var context: ContextSnapshot { working.snapshot }
    public var originalContext: ContextSnapshot { working.original }

    /// Caller edits use exactly the same validation and persistence boundary as model edits.
    public func apply(_ edit: ContextEdit) async throws {
        guard !busy else { throw ContextError.busy }
        busy = true
        defer { busy = false }
        var candidate = working
        try candidate.apply(edit)
        try Task.checkCancellation()
        try await persistence?.save(candidate.snapshot)
        working = candidate
    }

    /// Failures return a report with partial usage and the last valid revision; cancellation propagates.
    public func run(mode: RunMode = .editable, budget: RunBudget = RunBudget()) async throws -> RunReport {
        guard !busy else { throw ContextError.busy }
        busy = true
        defer { busy = false }
        let start = Date()
        let original = working.original
        let runStart = working.snapshot
        var beforeTokens: Int?
        var beforeFailure: String?
        var runStartTokens = 0
        var finalPrompt: PreparedPrompt?
        var calls: [PreparedPrompt] = []
        var attempts: [EditAttempt] = []
        var generated = 0
        var editCalls = 0
        var answer = ""
        var failure: String?
        var control: [ContextRecord] = []

        func checkBudget(_ prompt: PreparedPrompt, output: Int, reserve: Int = 0) throws {
            try Task.checkCancellation()
            guard prompt.tokenCount <= budget.contextWindow - output else {
                throw ContextError.budgetExceeded("input plus reserved output exceeds the context window")
            }
            let used = calls.reduce(0) { $0 + $1.tokenCount } + generated
            guard used <= budget.totalTokens - prompt.tokenCount - output - reserve else {
                throw ContextError.budgetExceeded("total input/output allowance cannot reserve the next completion")
            }
        }

        do {
            guard budget.contextWindow > 0, budget.totalTokens > 0,
                  budget.editOutputTokens > 0, budget.completionOutputTokens > 0,
                  budget.editOutputTokens <= 1_000_000,
                  budget.completionOutputTokens <= 1_000_000,
                  (1...4).contains(budget.maxEditAttempts),
                  budget.contextWindow <= 1_000_000, budget.totalTokens <= 10_000_000 else {
                throw ContextError.invalid("invalid run budget; edit attempts must be 1...4")
            }
            runStartTokens = try await counter.prepare(ModelInput(context: runStart, phase: .completion)).tokenCount
            if runStart == original { beforeTokens = runStartTokens }
            else {
                do { beforeTokens = try await counter.prepare(ModelInput(context: original, phase: .completion)).tokenCount }
                catch is CancellationError { throw CancellationError() }
                catch { beforeFailure = error.localizedDescription }
            }
            if mode == .editable {
                var accepted = false
                for attempt in 0..<budget.maxEditAttempts {
                    try Task.checkCancellation()
                    let prompt = try await counter.prepare(ModelInput(context: working.snapshot, phase: .edit, controlRecords: control))
                    try checkBudget(prompt, output: budget.editOutputTokens, reserve: budget.completionOutputTokens)
                    calls.append(prompt)
                    let response = try await backend.generate(prompt, maxTokens: budget.editOutputTokens)
                    try Task.checkCancellation()
                    guard response.generatedTokens >= 0, response.generatedTokens <= budget.editOutputTokens else {
                        throw ContextError.invalid("backend reported invalid token usage")
                    }
                    generated += response.generatedTokens
                    let arguments = response.toolCalls.map(\.arguments).joined(separator: "\n")
                    let reservedRecords = original.records + working.snapshot.records + control
                    let candidate: WorkingContext
                    let detail: String
                    let receipt: [ContextRecord]
                    let next: PreparedPrompt
                    do {
                        guard !response.reachedTokenLimit else { throw ContextError.budgetExceeded("edit generation hit its output limit") }
                        guard response.toolCalls.count == 1 else {
                            throw response.toolCalls.isEmpty ? ContextError.modelDidNotEdit : ContextError.invalid("one atomic edit_context call is allowed per attempt")
                        }
                        let call = response.toolCalls[0]
                        guard call.name == ContextEditTool.name else { throw ContextError.invalid("unknown context tool") }
                        editCalls += 1
                        let edit = try ContextEditTool.decode(arguments: call.arguments, scope: working.snapshot.scope)
                        var validated = working
                        try validated.apply(edit)
                        candidate = validated
                        detail = "Accepted revision \(candidate.snapshot.revision). Complete the initial task now."
                        receipt = Self.receipt(attempt: attempt, calls: response.toolCalls, text: detail,
                                               reserving: reservedRecords)
                        next = try await counter.prepare(ModelInput(context: candidate.snapshot, phase: .completion, controlRecords: receipt))
                        try checkBudget(next, output: budget.completionOutputTokens)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        let detail = error.localizedDescription
                        attempts.append(EditAttempt(arguments: arguments, modelText: response.text, accepted: false, detail: detail))
                        // Keep raw model values in the report, never in protected retry instructions.
                        // A rejected call may contain invalid JSON, tool names or template delimiters.
                        control = Self.receipt(attempt: attempt, calls: [],
                                               text: "Rejected: use a valid edit_context call with existing unprotected IDs and complete tool groups. Retry against revision \(working.snapshot.revision).",
                                               reserving: reservedRecords)
                        continue
                    }
                    // Storage errors are runtime failures, not defects the model can repair.
                    try Task.checkCancellation()
                    do { try await persistence?.save(candidate.snapshot) }
                    catch {
                        attempts.append(EditAttempt(arguments: arguments, modelText: response.text, accepted: false,
                                                    detail: "Commit failed: \(error.localizedDescription)"))
                        throw error
                    }
                    working = candidate
                    control = receipt
                    finalPrompt = next
                    attempts.append(EditAttempt(arguments: arguments, modelText: response.text, accepted: true, detail: detail))
                    accepted = true
                    break
                }
                guard accepted else { throw ContextError.editLimit }
            }
            try Task.checkCancellation()
            let prepared: PreparedPrompt
            if let finalPrompt { prepared = finalPrompt }
            else { prepared = try await counter.prepare(ModelInput(context: working.snapshot, phase: .completion)) }
            try checkBudget(prepared, output: budget.completionOutputTokens)
            finalPrompt = prepared
            calls.append(prepared)
            let response = try await backend.generate(prepared, maxTokens: budget.completionOutputTokens)
            try Task.checkCancellation()
            guard response.generatedTokens >= 0, response.generatedTokens <= budget.completionOutputTokens else {
                throw ContextError.invalid("backend reported invalid token usage")
            }
            generated += response.generatedTokens
            answer = response.text
            guard response.toolCalls.isEmpty else { throw ContextError.invalid("tools are disabled during completion") }
            guard !response.reachedTokenLimit else { throw ContextError.budgetExceeded("completion hit its output limit") }
        } catch is CancellationError { throw CancellationError() }
        catch { failure = error.localizedDescription }

        return RunReport(mode: mode, original: original, runStart: runStart, revised: working.snapshot,
                         originalPromptTokens: beforeTokens, originalPromptFailure: beforeFailure, runStartPromptTokens: runStartTokens,
                         finalPrompt: finalPrompt, calls: calls,
                         attempts: attempts, answer: answer, failure: failure,
                         totalInputTokens: calls.reduce(0) { $0 + $1.tokenCount },
                         totalGeneratedTokens: generated, editCallCount: editCalls,
                         elapsedSeconds: Date().timeIntervalSince(start))
    }

    private static func receipt(attempt: Int, calls: [ModelToolCall], text: String,
                                reserving records: [ContextRecord]) -> [ContextRecord] {
        // Caller IDs are opaque: reserve both kinds of ID, including deleted history and prior feedback.
        var used = Set(records.flatMap { [$0.id] + $0.toolCalls.map(\.id) + [$0.toolCallID].compactMap { $0 } })
        func freshID(_ preferred: String) -> String {
            var candidate = preferred
            var suffix = 0
            while !used.insert(candidate).inserted {
                suffix += 1
                candidate = "\(preferred)-\(suffix)"
            }
            return candidate
        }
        guard !calls.isEmpty else {
            return [ContextRecord(id: freshID("runtime-feedback-\(attempt)"), role: .user, body: text, isProtected: true)]
        }
        let links = calls.enumerated().map { index, call in
            ContextToolCall(id: freshID("runtime-edit-\(attempt)-\(index)"), name: call.name, arguments: call.arguments)
        }
        return [ContextRecord(id: freshID("runtime-call-\(attempt)"), role: .assistant, body: "", isProtected: true, toolCalls: links)]
            + links.map { ContextRecord(id: freshID("runtime-result-\($0.id)"), role: .tool, body: text, isProtected: true, toolCallID: $0.id) }
    }
}
