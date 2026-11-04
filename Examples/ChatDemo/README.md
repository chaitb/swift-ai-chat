# ChatDemo

An iOS 26 app that shows what a polished chat UI on top of `AIChat` looks like. It runs fully offline out of the box: `DemoTransport` streams scripted replies built from real `UIMessageChunk`s, with jittered timing, so every view sees the same data a live model would send.

## What it shows

| Try | Library feature | UI |
| --- | --- | --- |
| Weather in Lisbon | A client `ChatTool` (`get_weather`) run on device, then an automatic follow-up request | A tool card whose status symbol morphs from progress to a checkmark and expands into a forecast |
| Plan a weekend in Kyoto | Reasoning parts | A shimmering reasoning row that opens while it streams and folds away into "Thought for N seconds" |
| Book a table for two | A server-style approval (`tool-approval-request` → `addToolApprovalResponse`) | An approval card with haptic Approve and Deny buttons; the reply continues in the same message |
| What's new in Swift concurrency? | `source-url` parts | Numbered citation markers and a row of source chips |
| Show off some markdown | Streaming markdown | Headings, lists, quotes, rules and code blocks rendered natively, block by block |

Prompts are matched by keyword, so typing "weather in Tokyo" or "book dinner" works too. Anything else gets an intro reply.

Around those:

- Streamed text fades and un-blurs in glyph by glyph through a custom `TextRenderer`, with a soft pulsing caret.
- Your message flies from the composer into its bubble (`matchedGeometryEffect`), and a thinking indicator turns into the reply header.
- The Liquid Glass composer grows with the text, and its send button turns into a stop button while a reply streams.
- The list follows the stream while you're at the bottom. Scroll up and a "Jump to reply" pill appears.
- Chats are saved with `FileChatStore`. The list button switches, deletes and starts chats.
- Reduce Motion swaps blurs, flights and bounces for plain fades. Light and dark mode both work.

## Run it

Open `ChatDemo.swiftpm` in Xcode 26 and run the `ChatDemo` scheme on an iOS 26 simulator, or build from the command line:

```sh
cd Examples/ChatDemo/ChatDemo.swiftpm
xcodebuild -scheme ChatDemo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/xcode build
xcrun simctl install booted .build/xcode/Build/Products/Debug-iphonesimulator/ChatDemo.app
xcrun simctl launch booted dev.swiftaichat.ChatDemo
```

The package depends on the library by relative path (`../../..`), so edits to `Sources/` show up on the next build.

## Use a real model

Tap the gear and pick a backend:

- **Anthropic**: paste an API key. The app uses `AnthropicChatTransport` with summarized adaptive thinking and loads models into a `ModelPicker`.
- **OpenAI**: paste an API key. The app uses `OpenAIChatTransport` on the Responses API with reasoning summaries, and lists GPT-5 and o-series models.
- **AI SDK endpoint**: paste the URL of any route that returns `toUIMessageStreamResponse()`. The app uses `AISDKChatTransport`.

Keys are stored in the Keychain on the device. The `get_weather` tool is declared to every provider, so asking a real model about the weather renders the same card (with demo data). Without a key or URL, the app falls back to the offline demo.

Shipping a provider key inside an app exposes it. This is fine for a demo where you bring your own key; put a backend in front for anything else.

## Where things live

- `Sources/Demo`: `DemoTransport`, the scripts and the weather tool
- `Sources/App`: `AppModel` (the `Chat`, transports, `ModelPicker`, `FileChatStore`) and Keychain settings
- `Sources/Conversation`: the scroll view, composer, message rows and thinking indicator
- `Sources/Parts`: reasoning, tool, approval and source views
- `Sources/Markdown`: the block parser and the streaming text renderer
- `Sources/Screens`: root navigation, chat list and settings
