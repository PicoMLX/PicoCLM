import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import PicoContext

/// Text-only MLX adapter. Every generation starts from a fresh exact prompt and fresh KV state.
public actor MLXContextBackend: TokenCounting, ContextModelBackend {
    public static let modelID = "mlx-community/Qwen3-1.7B-4bit"
    public static let modelRevision = "3b1b1768f8f8cf8351c712464f906e86c2b8269e"
    private let container: ModelContainer
    private var generating = false

    private init(container: ModelContainer) { self.container = container }

    public static func load(directory: URL? = nil,
                            progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws -> MLXContextBackend {
        let configuration: ModelConfiguration
        if let directory { configuration = ModelConfiguration(directory: directory) }
        else { configuration = ModelConfiguration(id: modelID, revision: modelRevision) }
        let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) {
            progress($0.fractionCompleted)
        }
        return MLXContextBackend(container: container)
    }

    public func prepare(_ input: ModelInput) async throws -> PreparedPrompt {
        let preparedMessages = try Self.messages(for: input)
        let tools = input.phase == .edit ? [Self.editToolSchema(recordIDs: input.context.records.filter { !$0.isProtected }.map(\.id))] : nil
        // Apply the upstream tokenizer directly: missing templates must fail, never flatten roles.
        let tokens = try await container.perform { context in
            try context.tokenizer.applyChatTemplate(messages: preparedMessages, tools: tools,
                                                    additionalContext: ["enable_thinking": false])
        }
        let rendered = await container.decode(tokens: tokens)
        return PreparedPrompt(input: input, tokenIDs: tokens, renderedPrompt: rendered)
    }

    /// Build and validate prompt text before tokenization, independently of model loading.
    static func messages(for input: ModelInput) throws -> [Message] {
        try WorkingContext.validate(input.context)
        var messages: [Message] = [["role": "system", "content": input.instructions]]
        for record in input.context.records + input.controlRecords {
            let fields = [record.body, record.id] + [record.toolCallID].compactMap { $0 }
                + record.toolCalls.flatMap { [$0.id, $0.name] }
            guard !fields.contains(where: { field in
                ["<|im_start|>", "<|im_end|>", "<|endoftext|>",
                 "<tool_call>", "</tool_call>", "<tool_response>", "</tool_response>"].contains(where: field.contains)
            }) else {
                throw ContextError.invalid("record text or metadata contains a reserved Qwen delimiter")
            }
            // Metadata is descriptive text; actual roles and links are always supplied separately.
            var message: Message = [
                "role": record.role.rawValue,
                "content": "[recordID=\(record.id); protected=\(record.isProtected); callIDs=\(record.toolCalls.map(\.id).joined(separator: ",")); resultFor=\(record.toolCallID ?? "none")]\n\(record.body)",
            ]
            if !record.toolCalls.isEmpty {
                message["tool_calls"] = try record.toolCalls.map { call -> [String: any Sendable] in
                    let data = Data(call.arguments.utf8)
                    _ = try JSONDecoder().decode([String: JSONValue].self, from: data)
                    let function: [String: any Sendable] = [
                        "name": call.name, "arguments": call.arguments.replacingOccurrences(of: "<", with: "\\u003c"),
                    ]
                    return ["id": call.id, "type": "function", "function": function]
                }
            }
            if let link = record.toolCallID { message["tool_call_id"] = link }
            messages.append(message)
        }
        if input.phase == .edit {
            let editableResults = input.context.records.filter { $0.role == .tool && !$0.isProtected }.map(\.id).joined(separator: ", ")
            messages.append(["role": "user", "content": """
            This turn is the context editing phase. Call edit_context now, before giving an answer.
            Use replace to shorten verbose tool results into factual notes that preserve the requested facts.
            Editable tool-result record IDs: \(editableResults). Target these IDs; never target instructions or task.
            Each replacement must use these exact keys: action, recordID, body. Put the shorter text in body.
            Use baseRevision \(input.context.revision). Do not change protected instructions or the task.
            Return the function call inside <tool_call> and </tool_call>, with name and arguments fields.
            """])
        }
        return messages
    }

    public func generate(_ prompt: PreparedPrompt, maxTokens: Int) async throws -> ModelResponse {
        guard !generating else { throw ContextError.busy }
        guard !prompt.tokenIDs.isEmpty, maxTokens > 0 else { throw ContextError.invalid("empty prompt or output allowance") }
        generating = true
        defer { generating = false }
        try Task.checkCancellation()
        let (stream, task) = try await container.perform { context in
            let iterator = try TokenIterator(input: LMInput(tokens: MLXArray(prompt.tokenIDs)),
                                             model: context.model,
                                             parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0))
            return MLXLMCommon.generateTask(promptTokenCount: prompt.tokenCount,
                                           modelConfiguration: context.configuration,
                                           tokenizer: context.tokenizer, iterator: iterator)
        }
        return try await withTaskCancellationHandler {
            do {
                var text = ""
                var calls: [ModelToolCall] = []
                var tokenCount = 0
                var limit = false
                var completed = false
                for await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .chunk(let chunk): text += chunk
                    case .toolCall(let call):
                        let data = try JSONEncoder().encode(call.function.arguments)
                        calls.append(ModelToolCall(name: call.function.name, arguments: String(decoding: data, as: UTF8.self)))
                    case .info(let info):
                        completed = true
                        tokenCount = info.generationTokenCount
                        switch info.stopReason {
                        case .length: limit = true
                        case .cancelled: throw CancellationError()
                        case .stop: break
                        }
                    }
                }
                await task.value
                guard completed else { throw ContextError.invalid("MLX generation ended without token accounting") }
                // Some tokenizer decoders omit the wrapper tags. Accept only a complete JSON
                // function object using the upstream parser; the core still validates every edit.
                if calls.isEmpty, prompt.input.phase == .edit,
                   let call = JSONToolCallParser(startTag: "<tool_call>", endTag: "</tool_call>").parse(content: text, tools: nil) {
                    let data = try JSONEncoder().encode(call.function.arguments)
                    calls.append(ModelToolCall(name: call.function.name, arguments: String(decoding: data, as: UTF8.self)))
                }
                return ModelResponse(text: text, toolCalls: calls, generatedTokens: tokenCount, reachedTokenLimit: limit)
            } catch {
                task.cancel()
                await task.value
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    private static func editToolSchema(recordIDs: [String]) -> [String: any Sendable] {
        let action: [String: any Sendable] = ["type": "string", "enum": ["replace", "delete"]]
        let recordID: [String: any Sendable] = ["type": "string", "enum": recordIDs]
        let operationProperties: [String: any Sendable] = [
            "action": action, "recordID": recordID,
            "body": ["type": "string", "description": "Required for replace; omit for delete."],
        ]
        let operation: [String: any Sendable] = [
            "type": "object", "additionalProperties": false,
            "required": ["action", "recordID"], "properties": operationProperties,
        ]
        let operations: [String: any Sendable] = [
            "type": "array", "minItems": 1, "maxItems": 32, "items": operation,
        ]
        let properties: [String: any Sendable] = [
            "baseRevision": ["type": "integer", "description": "Current working-context revision."],
            "operations": operations,
        ]
        let parameters: [String: any Sendable] = [
            "type": "object", "additionalProperties": false,
            "required": ["baseRevision", "operations"], "properties": properties,
        ]
        let function: [String: any Sendable] = [
            "name": ContextEditTool.name,
            "description": "Atomically shorten unprotected working history by stable record IDs; keep all required facts.",
            "parameters": parameters,
        ]
        return ["type": "function", "function": function]
    }
}
