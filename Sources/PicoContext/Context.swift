import Foundation

/// Opaque caller-owned identifiers. The library never invents or merges scopes.
public struct ContextScope: Hashable, Codable, Sendable {
    public let userID: String
    public let conversationID: String
    public let branchID: String

    public init(userID: String, conversationID: String, branchID: String) {
        self.userID = userID
        self.conversationID = conversationID
        self.branchID = branchID
    }
}

public enum MessageRole: String, Codable, Sendable {
    case system, developer, user, assistant, tool
}

public struct ContextToolCall: Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ContextRecord: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let role: MessageRole
    public let body: String
    public let isProtected: Bool
    public let toolCalls: [ContextToolCall]
    public let toolCallID: String?

    public init(id: String, role: MessageRole, body: String, isProtected: Bool = false,
                toolCalls: [ContextToolCall] = [], toolCallID: String? = nil) {
        self.id = id
        self.role = role
        self.body = body
        self.isProtected = isProtected || role == .system || role == .developer
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    func replacingBody(_ body: String) -> Self {
        Self(id: id, role: role, body: body, isProtected: isProtected,
             toolCalls: toolCalls, toolCallID: toolCallID)
    }
}

public struct ContextSnapshot: Equatable, Codable, Sendable {
    public let scope: ContextScope
    public let revision: Int
    public let records: [ContextRecord]

    public init(scope: ContextScope, revision: Int = 0, records: [ContextRecord]) {
        self.scope = scope
        self.revision = revision
        self.records = records
    }
}

/// A caller-owned transaction. Models cannot create records or choose their metadata.
public struct ContextAppend: Equatable, Sendable {
    public let scope: ContextScope
    public let baseRevision: Int
    public let records: [ContextRecord]

    public init(scope: ContextScope, baseRevision: Int, records: [ContextRecord]) {
        self.scope = scope
        self.baseRevision = baseRevision
        self.records = records
    }
}

public enum ContextError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)
    case scopeMismatch
    case staleRevision(expected: Int, received: Int)
    case protectedRecord(String)
    case unknownRecord(String)
    case duplicateOperation(String)
    case incompleteToolGroup
    case busy
    case budgetExceeded(String)
    case editLimit
    case modelDidNotEdit

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): "Invalid context or edit: \(reason)"
        case .scopeMismatch: "The user, conversation or branch scope does not match."
        case .staleRevision(let expected, let received): "Stale revision \(received); expected \(expected)."
        case .protectedRecord(let id): "Record \(id) is protected."
        case .unknownRecord(let id): "Unknown record \(id)."
        case .duplicateOperation(let id): "More than one operation targets \(id)."
        case .incompleteToolGroup: "Delete an assistant tool call and all its results together."
        case .busy: "A context operation is already in progress."
        case .budgetExceeded(let reason): "Token budget exceeded: \(reason)"
        case .editLimit: "The bounded edit/recovery limit was reached."
        case .modelDidNotEdit: "The model did not call edit_context or keep_context."
        }
    }
}

/// Value semantics make validation and commit a single atomic mutation.
public struct WorkingContext: Sendable {
    /// Every caller-supplied record in arrival order, with its original body.
    public private(set) var original: ContextSnapshot
    public private(set) var snapshot: ContextSnapshot

    public init(_ snapshot: ContextSnapshot) throws {
        try Self.validate(snapshot)
        original = snapshot
        self.snapshot = snapshot
    }

    public static func validate(_ snapshot: ContextSnapshot) throws {
        guard snapshot.revision >= 0, snapshot.revision < Int.max,
              !snapshot.scope.userID.isEmpty, !snapshot.scope.conversationID.isEmpty,
              !snapshot.scope.branchID.isEmpty else { throw ContextError.invalid("empty scope or invalid revision") }
        guard !snapshot.records.isEmpty else { throw ContextError.invalid("empty history") }
        guard let task = snapshot.records.first(where: { $0.role == .user }), task.isProtected else {
            throw ContextError.invalid("the initial user task must be protected")
        }
        var ids = Set<String>()
        var callIDs = Set<String>()
        var pending = Set<String>()
        for record in snapshot.records {
            guard !record.id.isEmpty, ids.insert(record.id).inserted else {
                throw ContextError.invalid("empty or duplicate record ID")
            }
            if record.role == .system || record.role == .developer {
                guard record.isProtected else { throw ContextError.protectedRecord(record.id) }
            }
            if record.role == .tool {
                guard record.toolCalls.isEmpty, let id = record.toolCallID, pending.remove(id) != nil else {
                    throw ContextError.invalid("orphaned or duplicate tool result")
                }
            } else {
                guard pending.isEmpty else { throw ContextError.incompleteToolGroup }
                guard record.toolCallID == nil else { throw ContextError.invalid("result ID on a non-tool record") }
                if !record.toolCalls.isEmpty {
                    guard record.role == .assistant else { throw ContextError.invalid("only assistants call tools") }
                    // The assistant plus every result must fit one bounded 32-operation deletion.
                    guard record.toolCalls.count <= 31 else { throw ContextError.invalid("a tool group allows at most 31 calls") }
                    for call in record.toolCalls {
                        guard !call.id.isEmpty, !call.name.isEmpty, callIDs.insert(call.id).inserted else {
                            throw ContextError.invalid("empty or duplicate tool call ID/name")
                        }
                        pending.insert(call.id)
                    }
                }
            }
        }
        guard pending.isEmpty else { throw ContextError.incompleteToolGroup }
    }

    public mutating func apply(_ edit: ContextEdit) throws {
        guard edit.scope == snapshot.scope else { throw ContextError.scopeMismatch }
        guard edit.baseRevision == snapshot.revision else {
            throw ContextError.staleRevision(expected: snapshot.revision, received: edit.baseRevision)
        }
        guard !edit.operations.isEmpty, edit.operations.count <= 32 else {
            throw ContextError.invalid("an edit needs 1...32 operations")
        }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
        var touched = Set<String>()
        var replacements: [String: String] = [:]
        var deleted = Set<String>()
        for operation in edit.operations {
            let id = operation.recordID
            guard touched.insert(id).inserted else { throw ContextError.duplicateOperation(id) }
            guard let record = byID[id] else { throw ContextError.unknownRecord(id) }
            guard !record.isProtected else { throw ContextError.protectedRecord(id) }
            switch operation {
            case .replace(_, let body):
                guard body.utf8.count <= 64_000 else { throw ContextError.invalid("replacement too large") }
                replacements[id] = body
            case .delete: deleted.insert(id)
            }
        }
        let records = snapshot.records.compactMap { record -> ContextRecord? in
            if deleted.contains(record.id) { return nil }
            return replacements[record.id].map { record.replacingBody($0) } ?? record
        }
        let candidate = ContextSnapshot(scope: snapshot.scope, revision: snapshot.revision + 1, records: records)
        try Self.validate(candidate)
        guard candidate.records != snapshot.records else { throw ContextError.invalid("edit changes nothing") }
        snapshot = candidate
    }

    public mutating func append(_ transaction: ContextAppend) throws {
        guard transaction.scope == snapshot.scope else { throw ContextError.scopeMismatch }
        guard transaction.baseRevision == snapshot.revision else {
            throw ContextError.staleRevision(expected: snapshot.revision, received: transaction.baseRevision)
        }
        guard (1...64).contains(transaction.records.count),
              transaction.records.allSatisfy({ $0.body.utf8.count <= 64_000 }) else {
            throw ContextError.invalid("append needs 1...64 records with bodies at most 64000 bytes")
        }
        // Include metadata and arguments in the transaction bound, not just visible bodies.
        guard try JSONEncoder().encode(transaction.records).count <= 128_000 else {
            throw ContextError.invalid("append payload too large")
        }
        let revision = snapshot.revision + 1
        let transcript = ContextSnapshot(scope: snapshot.scope, revision: revision,
                                         records: original.records + transaction.records)
        let candidate = ContextSnapshot(scope: snapshot.scope, revision: revision,
                                        records: snapshot.records + transaction.records)
        // Validate against preserved history too: deleted IDs and call IDs cannot be reused.
        try Self.validate(transcript)
        try Self.validate(candidate)
        original = transcript
        snapshot = candidate
    }
}
