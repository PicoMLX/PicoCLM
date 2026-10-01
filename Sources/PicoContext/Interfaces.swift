import Foundation

public enum ModelPhase: String, Sendable { case edit, completion }

/// Guidance for the native edit tool; both styles share the same validation/commit boundary.
public enum ContextEditStyle: String, Codable, Sendable {
    case targeted, summarize
}

public struct ModelInput: Sendable {
    public let context: ContextSnapshot
    public let phase: ModelPhase
    public let editStyle: ContextEditStyle
    /// Runtime-owned control exchange, separate from editable history.
    public let controlRecords: [ContextRecord]

    public init(context: ContextSnapshot, phase: ModelPhase, controlRecords: [ContextRecord] = [],
                editStyle: ContextEditStyle = .targeted) {
        self.context = context
        self.phase = phase
        self.editStyle = editStyle
        self.controlRecords = controlRecords
    }

    public var instructions: String {
        switch phase {
        case .edit:
            ContextEditTool.instructions
                + (editStyle == .summarize ? "\n" + ContextEditTool.summarizationInstructions : "")
                + "\nCurrent baseRevision: \(context.revision)."
        case .completion: "Respond to the latest caller-owned user request using the current working history. Follow the protected instructions and initial task. Context editing is finished."
        }
    }
}

/// Tokens include the chat template and tool schema. The backend consumes these exact IDs.
public struct PreparedPrompt: Sendable {
    public let input: ModelInput
    public let tokenIDs: [Int]
    public let renderedPrompt: String
    public var tokenCount: Int { tokenIDs.count }

    public init(input: ModelInput, tokenIDs: [Int], renderedPrompt: String) {
        self.input = input
        self.tokenIDs = tokenIDs
        self.renderedPrompt = renderedPrompt
    }
}

public protocol TokenCounting: Sendable {
    func prepare(_ input: ModelInput) async throws -> PreparedPrompt
}

public struct ModelToolCall: Sendable {
    public let name: String
    public let arguments: String
    public init(name: String = ContextEditTool.name, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct ModelResponse: Sendable {
    public let text: String
    public let toolCalls: [ModelToolCall]
    public let generatedTokens: Int
    public let reachedTokenLimit: Bool
    public init(text: String = "", toolCalls: [ModelToolCall] = [], generatedTokens: Int, reachedTokenLimit: Bool = false) {
        self.text = text
        self.toolCalls = toolCalls
        self.generatedTokens = generatedTokens
        self.reachedTokenLimit = reachedTokenLimit
    }
}

public protocol ContextModelBackend: Sendable {
    func generate(_ prompt: PreparedPrompt, maxTokens: Int) async throws -> ModelResponse
}

/// An optional commit hook. A failed save must throw before publishing any new state.
/// Durable implementations and multi-writer coordination are outside this prototype.
public protocol ContextPersistence: Sendable {
    func save(_ snapshot: ContextSnapshot) async throws
}

public actor InMemoryContextPersistence: ContextPersistence {
    private var snapshots: [ContextScope: ContextSnapshot] = [:]
    public init() {}
    public func save(_ snapshot: ContextSnapshot) { snapshots[snapshot.scope] = snapshot }
    public func load(scope: ContextScope) -> ContextSnapshot? { snapshots[scope] }
}
