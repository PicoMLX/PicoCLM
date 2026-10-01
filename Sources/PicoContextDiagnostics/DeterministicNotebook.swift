import Foundation
import PicoContext

/// A UTF-8 byte counter for protocol tests, not a model tokenizer or performance estimate.
public struct DiagnosticByteCounter: TokenCounting {
    public init() {}
    public func prepare(_ input: ModelInput) async throws -> PreparedPrompt {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = input.instructions + "\n" + String(decoding: try encoder.encode(input.context.records + input.controlRecords), as: UTF8.self)
        return PreparedPrompt(input: input, tokenIDs: text.utf8.map(Int.init), renderedPrompt: text)
    }
}

/// Derives answers from actual live FACT/REMOVE lines; never receives fixture answers.
public struct DeterministicNotebookBackend: ContextModelBackend {
    public init() {}
    public func generate(_ prompt: PreparedPrompt, maxTokens: Int) async throws -> ModelResponse {
        try Task.checkCancellation()
        guard maxTokens > 0 else { throw ContextError.invalid("positive output allowance required") }
        if prompt.input.phase == .edit {
            // Summaries consolidate every editable body, including caller-appended
            // answers. Body replacements preserve all roles and tool relationships.
            let records = prompt.input.context.records.filter {
                !$0.isProtected && (prompt.input.editStyle == .summarize || $0.role == .tool)
            }
            let state = DiagnosticGrading.retainedState(in: prompt.input.context)
            let summary = state.keys.sorted().map { "FACT \($0)=\(state[$0]!)" }.joined(separator: "\n")
            let operations = records.compactMap { record -> [String: String]? in
                let body: String
                if prompt.input.editStyle == .summarize {
                    body = record.id == records.last?.id ? summary : ""
                } else {
                    body = record.body.components(separatedBy: "\n").filter {
                        $0.hasPrefix("FACT ") || $0.hasPrefix("REMOVE ")
                    }.joined(separator: "\n")
                }
                return body == record.body ? nil : ["action": "replace", "recordID": record.id, "body": body]
            }
            let changes = prompt.input.editStyle == .summarize && operations.count > 32 ? [] : Array(operations.prefix(32))
            let arguments: [String: Any] = changes.isEmpty ? ["baseRevision": prompt.input.context.revision]
                : ["baseRevision": prompt.input.context.revision, "operations": changes]
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            let text = String(decoding: data, as: UTF8.self)
            let count = text.utf8.count
            guard count <= maxTokens else { return ModelResponse(text: Self.prefix(text, bytes: maxTokens), generatedTokens: maxTokens, reachedTokenLimit: true) }
            return ModelResponse(toolCalls: [ModelToolCall(name: changes.isEmpty ? ContextKeepTool.name : ContextEditTool.name,
                                                          arguments: text)], generatedTokens: count)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(["facts": DiagnosticGrading.retainedState(in: prompt.input.context)])
        let answer = String(decoding: data, as: UTF8.self)
        return ModelResponse(text: Self.prefix(answer, bytes: maxTokens), generatedTokens: min(answer.utf8.count, maxTokens),
                             reachedTokenLimit: answer.utf8.count > maxTokens)
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        var data = Data(text.utf8.prefix(bytes))
        // Preserve valid Unicode when a byte allowance cuts through a scalar.
        while String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
}
