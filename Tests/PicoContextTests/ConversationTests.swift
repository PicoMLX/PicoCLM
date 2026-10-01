import Foundation
import Testing
@testable import PicoContext

private let conversationScope = ContextScope(userID: "reader", conversationID: "notebook", branchID: "draft")
private let conversationBudget = RunBudget(contextWindow: 32_000, totalTokens: 120_000)

private func conversation() -> ContextSnapshot {
    ContextSnapshot(scope: conversationScope, records: [
        ContextRecord(id: "instructions", role: .system, body: "Keep exact notebook entries."),
        ContextRecord(id: "task", role: .user, body: "Answer each notebook request.", isProtected: true),
        ContextRecord(id: "note", role: .assistant, body: "Verbose note: code AZ-81.")
    ])
}

private struct ConversationCounter: TokenCounting {
    func prepare(_ input: ModelInput) async -> PreparedPrompt {
        let text = input.instructions + (input.context.records + input.controlRecords).map(\.body).joined(separator: "\n")
        return PreparedPrompt(input: input, tokenIDs: text.utf8.map(Int.init), renderedPrompt: text)
    }
}

private actor KeepingBackend: ContextModelBackend {
    private(set) var prompts: [PreparedPrompt] = []
    var firstArguments: String?
    init(firstArguments: String? = nil) { self.firstArguments = firstArguments }
    func generate(_ prompt: PreparedPrompt, maxTokens: Int) -> ModelResponse {
        prompts.append(prompt)
        if prompt.input.phase == .edit {
            let arguments = firstArguments ?? "{\"baseRevision\":\(prompt.input.context.revision)}"
            firstArguments = nil
            return ModelResponse(toolCalls: [ModelToolCall(name: ContextKeepTool.name, arguments: arguments)], generatedTokens: 8)
        }
        let latest = prompt.input.context.records.last { $0.role == .user }?.body ?? ""
        return ModelResponse(text: "Received: \(latest)", generatedTokens: 4)
    }
}

private struct UnavailableStore: ContextPersistence {
    func save(_ snapshot: ContextSnapshot) throws { throw ContextError.invalid("store unavailable") }
}

@Test func appendExtendsBothViewsWithoutRestoringEditedBodies() throws {
    var working = try WorkingContext(conversation())
    try working.apply(ContextEdit(scope: conversationScope, baseRevision: 0, operations: [
        .replace(recordID: "note", body: "AZ-81")
    ]))
    let records = [ContextRecord(id: "question-1", role: .user, body: "Recall the code.", isProtected: true)]
    try working.append(ContextAppend(scope: conversationScope, baseRevision: 1, records: records))
    #expect(working.snapshot.revision == 2)
    #expect(working.original.revision == 2)
    #expect(working.original.records == conversation().records + records)
    #expect(working.snapshot.records.first { $0.id == "note" }?.body == "AZ-81")
    #expect(working.original.records.first { $0.id == "note" }?.body == "Verbose note: code AZ-81.")
    #expect(working.snapshot.records.last == records[0])
}

@Test(arguments: [
    ContextScope(userID: "other", conversationID: "notebook", branchID: "draft"),
    ContextScope(userID: "reader", conversationID: "other", branchID: "draft"),
    ContextScope(userID: "reader", conversationID: "notebook", branchID: "other")
])
func appendRejectsEveryCrossScopeDimension(other: ContextScope) throws {
    var working = try WorkingContext(conversation())
    #expect(throws: ContextError.scopeMismatch) {
        try working.append(ContextAppend(scope: other, baseRevision: 0, records: [ContextRecord(id: "next", role: .user, body: "next")]))
    }
    #expect(working.original == conversation())
    #expect(working.snapshot == conversation())
}

@Test func staleAppendLeavesBothViewsIntact() throws {
    var working = try WorkingContext(conversation())
    let records = [ContextRecord(id: "next", role: .user, body: "next")]
    try working.append(ContextAppend(scope: conversationScope, baseRevision: 0, records: records))
    let original = working.original
    let snapshot = working.snapshot
    #expect(throws: ContextError.staleRevision(expected: 1, received: 0)) {
        try working.append(ContextAppend(scope: conversationScope, baseRevision: 0, records: records))
    }
    #expect(working.original == original)
    #expect(working.snapshot == snapshot)
}

private func lookupGroup() -> [ContextRecord] {
    [ContextRecord(id: "lookup", role: .assistant, body: "", toolCalls: [
        ContextToolCall(id: "lookup-call", name: "lookup", arguments: "{}")
    ]), ContextRecord(id: "lookup-result", role: .tool, body: "AZ-81", toolCallID: "lookup-call")]
}

@Test(arguments: [false, true])
func appendCannotReuseDeletedRecordOrToolCallIDs(reuseCallID: Bool) throws {
    var working = try WorkingContext(ContextSnapshot(scope: conversationScope, records: conversation().records + lookupGroup()))
    try working.apply(ContextEdit(scope: conversationScope, baseRevision: 0, operations: lookupGroup().map { .delete(recordID: $0.id) }))
    let before = working.snapshot
    let original = working.original
    let records = reuseCallID ? [
        ContextRecord(id: "new-lookup", role: .assistant, body: "", toolCalls: [ContextToolCall(id: "lookup-call", name: "lookup", arguments: "{}")]),
        ContextRecord(id: "new-result", role: .tool, body: "new", toolCallID: "lookup-call")
    ] : [ContextRecord(id: "lookup-result", role: .assistant, body: "new")]
    #expect(throws: (any Error).self) {
        try working.append(ContextAppend(scope: conversationScope, baseRevision: 1, records: records))
    }
    #expect(working.snapshot == before)
    #expect(working.original == original)
}

@Test(arguments: [0, 1])
func incompleteAppendedToolGroupIsAtomic(part: Int) throws {
    var working = try WorkingContext(conversation())
    #expect(throws: (any Error).self) {
        try working.append(ContextAppend(scope: conversationScope, baseRevision: 0, records: [lookupGroup()[part]]))
    }
    #expect(working.original == conversation())
    #expect(working.snapshot == conversation())
}

@Test func completeAppendedToolGroupRetainsCallerMetadata() throws {
    var working = try WorkingContext(conversation())
    try working.append(ContextAppend(scope: conversationScope, baseRevision: 0, records: lookupGroup()))
    #expect(Array(working.snapshot.records.suffix(2)) == lookupGroup())
    #expect(Array(working.original.records.suffix(2)) == lookupGroup())
}

@Test(arguments: [0, 1, 2, 3])
func appendBoundsRecordsBodiesAndMetadata(kind: Int) throws {
    let records: [ContextRecord]
    switch kind {
    case 0: records = []
    case 1: records = (0..<65).map { ContextRecord(id: "r-\($0)", role: .assistant, body: "small") }
    case 2: records = [ContextRecord(id: "huge", role: .assistant, body: String(repeating: "x", count: 64_001))]
    default: records = [ContextRecord(id: String(repeating: "x", count: 128_001), role: .assistant, body: "small")]
    }
    var working = try WorkingContext(conversation())
    #expect(throws: (any Error).self) {
        try working.append(ContextAppend(scope: conversationScope, baseRevision: 0, records: records))
    }
    #expect(working.snapshot == conversation())
    #expect(working.original == conversation())
}

@Test func appendSaveFailurePreservesTranscriptAndWorkingRevision() async throws {
    let session = try ContextSession(context: conversation(), counter: ConversationCounter(), backend: KeepingBackend(), persistence: UnavailableStore())
    await #expect(throws: ContextError.invalid("store unavailable")) {
        try await session.append(ContextAppend(scope: conversationScope, baseRevision: 0, records: [ContextRecord(id: "next", role: .user, body: "new")]))
    }
    #expect(await session.context == conversation())
    #expect(await session.originalContext == conversation())
    // A keep decision does not write a new revision or require storage.
    let report = try await session.run(budget: conversationBudget)
    #expect(report.failure == nil)
    #expect(report.attempts.map(\.outcome) == [.kept])
}

@Test func appendedRequestReachesNextCallAndAnswersAppendOnlyByCallerChoice() async throws {
    let backend = KeepingBackend()
    let store = InMemoryContextPersistence()
    let session = try ContextSession(context: conversation(), counter: ConversationCounter(), backend: backend, persistence: store)
    let request = ContextRecord(id: "request", role: .user, body: "Recall AZ-81 exactly.", isProtected: true)
    try await session.append(ContextAppend(scope: conversationScope, baseRevision: 0, records: [request]))
    let report = try await session.run(budget: conversationBudget)
    #expect(report.failure == nil)
    #expect(report.answer == "Received: Recall AZ-81 exactly.")
    #expect(report.revised == report.runStart)
    #expect(report.attempts.map(\.outcome) == [.kept])
    #expect(report.editCallCount == 0)
    #expect(report.keepCallCount == 1)
    #expect(report.totalGeneratedTokens == 12)
    #expect(report.original.records == conversation().records + [request])
    let prompts = await backend.prompts
    #expect(prompts.count == 2)
    #expect(prompts.allSatisfy { $0.input.context == report.revised })
    #expect(prompts.last?.tokenIDs == report.finalPrompt?.tokenIDs)
    #expect(prompts.last?.input.controlRecords.last?.body.contains("Kept revision 1") == true)
    #expect(await session.context == report.revised) // Completion itself did not append.
    let reply = ContextRecord(id: "reply", role: .assistant, body: report.answer)
    try await session.append(ContextAppend(scope: conversationScope, baseRevision: report.revised.revision, records: [reply]))
    #expect(await session.originalContext.records.last == reply)
    #expect(await session.context.records.last == reply)
    #expect(await store.load(scope: conversationScope)?.revision == 2)
}

@Test(arguments: ["{}", "{\"baseRevision\":true}", "{\"baseRevision\":1}", "{\"baseRevision\":0,\"operations\":[]}", "not JSON"])
func invalidKeepDecisionsAreRejectedThenRepaired(arguments: String) async throws {
    let backend = KeepingBackend(firstArguments: arguments)
    let session = try ContextSession(context: conversation(), counter: ConversationCounter(), backend: backend)
    let report = try await session.run(budget: conversationBudget)
    #expect(report.failure == nil)
    #expect(report.attempts.map(\.outcome) == [.rejected, .kept])
    #expect(report.keepCallCount == 2)
    #expect(report.revised == conversation())
    #expect(report.calls.count == 3)
    #expect(report.totalGeneratedTokens == 20)
    #expect(report.calls[1].input.controlRecords.last?.body.contains("Rejected:") == true)
}

private actor PausingStore: ContextPersistence {
    var entered = false
    var watchers: [CheckedContinuation<Void, Never>] = []
    var gate: CheckedContinuation<Void, Never>?
    func save(_ snapshot: ContextSnapshot) async {
        await withCheckedContinuation { continuation in
            gate = continuation
            entered = true
            watchers.forEach { $0.resume() }
            watchers.removeAll()
        }
    }
    func waitForSave() async {
        if entered { return }
        await withCheckedContinuation { watchers.append($0) }
    }
    func resume() { gate?.resume(); gate = nil }
}

@Test func appendPublishesBothViewsTogetherAndRejectsReentrancyDuringSave() async throws {
    let store = PausingStore()
    let session = try ContextSession(context: conversation(), counter: ConversationCounter(), backend: KeepingBackend(), persistence: store)
    let transaction = ContextAppend(scope: conversationScope, baseRevision: 0, records: [ContextRecord(id: "next", role: .user, body: "new")])
    let append = Task { try await session.append(transaction) }
    await store.waitForSave()
    #expect(await session.context == conversation())
    #expect(await session.originalContext == conversation())
    await #expect(throws: ContextError.busy) { try await session.append(transaction) }
    await #expect(throws: ContextError.busy) { try await session.run(budget: conversationBudget) }
    await store.resume()
    try await append.value
    #expect(await session.context.records.last?.id == "next")
    #expect(await session.originalContext.records.last?.id == "next")
}
