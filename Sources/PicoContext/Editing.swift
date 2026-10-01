import Foundation

public enum ContextOperation: Equatable, Sendable {
    case replace(recordID: String, body: String)
    case delete(recordID: String)

    public var recordID: String {
        switch self {
        case .replace(let id, _), .delete(let id): id
        }
    }
}

public struct ContextEdit: Equatable, Sendable {
    public let scope: ContextScope
    public let baseRevision: Int
    public let operations: [ContextOperation]

    public init(scope: ContextScope, baseRevision: Int, operations: [ContextOperation]) {
        self.scope = scope
        self.baseRevision = baseRevision
        self.operations = operations
    }
}

/// Only this deliberately narrow JSON payload is model-owned. Scope comes from the caller.
public enum ContextEditTool {
    public static let name = "edit_context"
    public static let instructions = """
    Decide whether to edit working history before answering the latest user request on the next call.
    Call edit_context for useful changes, or keep_context with baseRevision to explicitly keep it unchanged.
    Replace verbose record bodies with short factual notes. Keep exact facts required by the task.
    Delete stale records only when their complete assistant/tool result group can be deleted together.
    IDs, roles, protection and tool links cannot be edited. Never edit a protected record.
    Make one atomic call with baseRevision and operations. Each operation has action (replace or delete),
    recordID, and body for replace. Do not include scope, roles or new records. Do not answer yet.
    """

    /// Original whole-history summary guidance using caller-owned records, never new identities.
    public static let summarizationInstructions = """
    Use a whole-history summarization policy for this decision.
    Review all unprotected history and consolidate the task-relevant current state into concise notes.
    Put the summary in an existing unprotected record body, preserving exact required values.
    Remove superseded information in the same atomic edit, using body replacements or complete group deletions.
    Keep effective removals and update order; do not resurrect stale facts from earlier history.
    Preserve protected records, roles, IDs and tool relationships. Do not create a summary record.
    If no useful legal summary is possible, call keep_context. Do not answer during this phase.
    """

    public static func decode(arguments: String, scope: ContextScope) throws -> ContextEdit {
        guard arguments.utf8.count <= 128_000,
              let data = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["baseRevision", "operations"],
              let operations = object["operations"] as? [[String: Any]] else {
            throw ContextError.invalid("expected baseRevision integer and operations array")
        }
        let revisionData = try JSONSerialization.data(withJSONObject: object["baseRevision"]!, options: .fragmentsAllowed)
        let number = try JSONDecoder().decode(Int.self, from: revisionData)
        let decoded = try operations.map { operation -> ContextOperation in
            guard let action = operation["action"] as? String,
                  let id = operation["recordID"] as? String else {
                throw ContextError.invalid("operation needs action and recordID")
            }
            switch action {
            case "replace":
                guard Set(operation.keys) == ["action", "recordID", "body"], let body = operation["body"] as? String else {
                    throw ContextError.invalid("replace needs only action, recordID and body")
                }
                return .replace(recordID: id, body: body)
            case "delete":
                guard Set(operation.keys) == ["action", "recordID"] else {
                    throw ContextError.invalid("delete needs only action and recordID")
                }
                return .delete(recordID: id)
            default: throw ContextError.invalid("unknown action")
            }
        }
        return ContextEdit(scope: scope, baseRevision: number, operations: decoded)
    }
}

/// A deliberate no-edit decision, separate from a missing tool call or an empty edit.
public enum ContextKeepTool {
    public static let name = "keep_context"

    public static func validate(arguments: String, revision: Int) throws {
        guard arguments.utf8.count <= 1_024,
              let object = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              Set(object.keys) == ["baseRevision"] else {
            throw ContextError.invalid("keep_context needs only baseRevision")
        }
        let data = try JSONSerialization.data(withJSONObject: object["baseRevision"]!, options: .fragmentsAllowed)
        let received = try JSONDecoder().decode(Int.self, from: data)
        guard received == revision else { throw ContextError.staleRevision(expected: revision, received: received) }
    }
}
