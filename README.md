# swift-ai-chat

A headless chat client for Swift, modeled on the [AI SDK](https://ai-sdk.dev)'s `useChat`. It holds the conversation, streams responses, runs client-side tools and handles approvals. You bring the views.

It talks to three kinds of backend:

- **AI SDK backends.** Any server that returns `toUIMessageStreamResponse()` (AI SDK v6 and v7), with resumable streams and custom `data-*` parts.
- **Anthropic.** The Messages API directly, with thinking, hosted tools like web search, citations and `pause_turn` handling.
- **OpenAI.** The Responses API or Chat Completions, which also covers OpenAI-compatible servers such as the Vercel AI Gateway, OpenRouter, Groq or a local model.

Swift 6 with strict concurrency. iOS 17, macOS 14, watchOS 10, tvOS 17 and visionOS 1.

## Install

```swift
.package(url: "https://github.com/chaitb/swift-ai-chat", from: "0.1.0")
```

Then add the products you need: `AIChat` always, plus `AIChatAnthropic` or `AIChatOpenAI` for a direct provider. `AIChatTesting` has a mock transport and a stub HTTP client for your own tests.

## Quick start

```swift
import AIChat
import SwiftUI

struct ChatView: View {
    @State private var chat = Chat(transport: AISDKChatTransport(api: URL(string: "https://example.com/api/chat")!))
    @State private var draft = ""

    var body: some View {
        List(chat.messages) { message in
            Text(message.text)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("Message", text: $draft)
                if chat.isBusy {
                    Button("Stop") { chat.stop() }
                } else {
                    Button("Send") {
                        let text = draft
                        draft = ""
                        Task { await chat.sendMessage(text) }
                    }
                }
            }
            .padding()
        }
    }
}
```

`Chat` is `@MainActor` and `@Observable`. `messages`, `status` and `error` drive your UI. Every message is a list of typed parts, so you can render text, reasoning, tool calls, sources, files and data parts each in their own view:

```swift
ForEach(message.parts) { part in
    switch part {
    case .text(let text): Markdown(text.text)
    case .reasoning(let reasoning): ThinkingView(reasoning)
    case .tool(let tool): ToolCallRow(tool)
    case .data(let data) where data.name == "weather": WeatherCard(try? data.decode(Weather.self))
    default: EmptyView()
    }
}
```

## Talking to a provider directly

```swift
import AIChatAnthropic
import AIChatOpenAI

let claude = Chat(transport: AnthropicChatTransport(apiKey: anthropicKey, model: "claude-opus-5-5"))

var configuration = OpenAIConfiguration.apiKey(openAIKey)
configuration.reasoning = .init(effort: .medium, summary: .auto)
let gpt = Chat(transport: OpenAIChatTransport(configuration: configuration))
```

Direct transports send the whole conversation each turn. Anthropic thinking keeps its signature and OpenAI reasoning goes back as encrypted content, so the model keeps its chain of thought across tool calls without any server-side state.

Shipping a provider key inside an app exposes it to anyone who has the app. Use direct transports for tools, prototypes and apps where users bring their own key, and put a backend in front for everything else.

## Tools

Register tools on the chat. Direct transports declare them to the model, and the chat runs them on device and sends the results back until the model answers.

```swift
let weather = ChatTool(
    name: "get_weather",
    description: "The current weather for a city",
    inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]
) { call in
    try await WeatherService.current(city: call.input["city"]?.stringValue ?? "")
}

let chat = Chat(transport: transport, configuration: ChatConfiguration(tools: [weather]))
```

A tool with `needsApproval: true` waits in the `approval-requested` state. Answer it with:

```swift
await chat.addToolApprovalResponse(approvalID: approval.id, approved: true)
```

Tools without an `execute` closure are answered by your UI through `onToolCall` and `addToolOutput(toolCallId:output:)`, like a survey or a confirmation sheet. Approvals the server asks for (AI SDK `needsApproval` tools) use the same call.

## Picking a model

`ModelPicker` loads a catalog and remembers the user's choice. Catalogs exist for Anthropic, OpenAI and the Vercel AI Gateway, and `CompositeModelCatalog` merges several.

```swift
@State private var picker = ModelPicker(
    catalog: AnthropicModelCatalog(apiKey: key),
    defaultModelID: "claude-opus-5-5",
    storageKey: "chat.model"
)

Picker("Model", selection: $picker.selectedModelID) {
    ForEach(picker.models) { Text($0.displayName).tag(Optional($0.id)) }
}
.task { await picker.load() }
.onChange(of: picker.selectedModelID) { chat.modelID = $1 }
```

With `RoutingChatTransport`, one chat can switch between providers: a model id like `anthropic/claude-opus-5-5` goes to the Anthropic route and `openai/gpt-5.5` to the OpenAI one.

## AI SDK backends

`AISDKChatTransport` sends the request body the AI SDK's `DefaultChatTransport` sends (`id`, `messages`, `trigger`, `messageId`) and reads the UI message stream. Use `prepareSendMessagesRequest` to reshape it, for example to send only the newest message when your server keeps the history:

```swift
let transport = AISDKChatTransport(
    api: URL(string: "https://example.com/api/chat")!,
    dynamicHeaders: { ["Authorization": "Bearer \(try await auth.token())"] },
    prepareSendMessagesRequest: { request, prepared in
        var prepared = prepared
        prepared.body = ["id": .string(request.chatID), "message": request.messages.last?.jsonValue ?? .null]
        return prepared
    }
)
```

Streams the server marks resumable reconnect with `resumeStream()`, or on their own with a `ResumePolicy`.

## Saving conversations

Set a `ChatStore` and the chat saves after every user message and finished response. `FileChatStore` writes JSON files to Application Support; implement the protocol for SwiftData, GRDB or your server.

```swift
let chat = try await Chat.restore(id: savedID, transport: transport, configuration: ChatConfiguration(store: FileChatStore()))
```

## Errors

Every failure surfaces as a `ChatError` with a kind, the provider's error code, the HTTP status, the request id and whether a retry may help. Text that streamed before an error stays in the message.

## Example

[`Examples/ChatCLI`](Examples/ChatCLI) runs a tool-using conversation against any backend:

```sh
cd Examples/ChatCLI
OPENAI_API_KEY=… swift run ChatCLI openai
ANTHROPIC_API_KEY=… swift run ChatCLI anthropic
AI_GATEWAY_API_KEY=… swift run ChatCLI openai-chat
swift run ChatCLI aisdk https://example.com/api/chat
```

With only `AI_GATEWAY_API_KEY` set, every provider is reached through the Vercel AI Gateway.

## License

MIT
