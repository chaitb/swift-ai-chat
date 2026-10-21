import AIChat
import AIChatAnthropic
import AIChatOpenAI
import Foundation

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())
let backend = arguments.first ?? "openai"
let gatewayKey = environment["AI_GATEWAY_API_KEY"]

func makeTransport() -> (any ChatTransport)? {
    switch backend {
    case "anthropic":
        if let key = environment["ANTHROPIC_API_KEY"] {
            return AnthropicChatTransport(apiKey: key, model: "claude-haiku-5-5")
        }
        guard let gatewayKey else { return nil }
        return AnthropicChatTransport(configuration: AnthropicConfiguration(
            authentication: .apiKey(gatewayKey),
            baseURL: URL(string: "https://ai-gateway.vercel.sh")!,
            defaultModel: "anthropic/claude-haiku-5.5",
            maxTokens: 4_000
        ))
    case "openai", "openai-chat":
        let api: OpenAIConfiguration.API = backend == "openai" ? .responses : .chatCompletions
        var configuration: OpenAIConfiguration
        if let key = environment["OPENAI_API_KEY"] {
            configuration = .apiKey(key, api: api, defaultModel: "gpt-5.4-mini")
        } else if let gatewayKey {
            configuration = .aiGateway(apiKey: gatewayKey, api: api, defaultModel: "openai/gpt-5.4-mini")
        } else {
            return nil
        }
        configuration.reasoning = .init(effort: .low, summary: .auto)
        return OpenAIChatTransport(configuration: configuration)
    case "aisdk":
        guard arguments.count > 1, let url = URL(string: arguments[1]) else { return nil }
        var headers: [String: String] = [:]
        if let cookie = environment["CHAT_COOKIE"] { headers["cookie"] = cookie }
        return AISDKChatTransport(api: url, headers: headers)
    default:
        return nil
    }
}

guard let transport = makeTransport() else {
    print("usage: ChatCLI anthropic|openai|openai-chat|aisdk <url>")
    print("Set ANTHROPIC_API_KEY, OPENAI_API_KEY or AI_GATEWAY_API_KEY.")
    exit(1)
}

let weather = ChatTool(
    name: "get_weather",
    description: "The current weather for a city",
    inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]
) { call in
    ["city": call.input["city"] ?? "", "celsius": 21, "sky": "sunny"]
}

@MainActor
func run() async {
    let chat = Chat(transport: transport, configuration: ChatConfiguration(tools: backend == "aisdk" ? [] : [weather]))
    let prompts = backend == "aisdk"
        ? ["Say hello in five words."]
        : ["What's the weather in Lisbon? Use the tool, then answer in one sentence.", "Is it warmer than 15°C there? Answer yes or no."]
    for prompt in prompts {
        print("> \(prompt)")
        await chat.sendMessage(prompt)
        while chat.isBusy { try? await Task.sleep(for: .milliseconds(50)) }
        if let error = chat.error {
            print("error: \(error.message) [\(error.code ?? "-")]")
            exit(2)
        }
        guard let reply = chat.messages.last else { continue }
        print("parts: \(reply.parts.map(\.type).joined(separator: ", "))")
        for part in reply.parts {
            if let reasoning = part.reasoningPart, !reasoning.text.isEmpty { print("reasoning: \(reasoning.text.prefix(120))") }
            if let tool = part.toolPart { print("tool \(tool.toolName): \(tool.state.rawValue) \(tool.input?.jsonString ?? "") -> \(tool.output?.jsonString ?? "")") }
        }
        print("text: \(reply.text)")
        print("metadata: \(reply.metadata?.jsonString ?? "none")\n")
    }
}

await run()
