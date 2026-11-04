import AIChat
import SwiftUI

struct ConversationView: View {
    var chat: Chat
    var assistantName: String
    var emptySubtitle: String

    @Namespace private var namespace
    @State private var draft = ""
    @State private var flight: Flight?
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @State private var following = true
    @State private var viewportHeight: CGFloat = 0
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleMessagesList: [UIMessage] {
        chat.messages.filter { message in
            guard message.role != .system else { return false }
            guard let flight, !flight.landed else { return true }
            return message.id != flight.id
        }
    }


    private var showsEmptyState: Bool {
        chat.messages.isEmpty && flight == nil
    }

    var body: some View {
        let visibleMessages = visibleMessagesList
        let turns = turnIDs(for: visibleMessages)
        let showsPending = chat.isBusy && flight == nil && visibleMessages.last?.role == .user
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                    row(for: message, turnID: turns[index], isLast: index == visibleMessages.count - 1)
                        .id(message.id)
                        .transition(message.role == .user ? .identity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 14)),
                            removal: .opacity
                        ))
                }
                if showsPending {
                    ThinkingIndicator(name: assistantName, turnID: visibleMessages.last?.id ?? "", namespace: namespace)
                }
                if chat.status == .error, let error = chat.error {
                    ErrorBanner(error: error) {
                        Task { await chat.regenerate() }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .bottom)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.22), value: visibleMessages.map(\.id))
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.2), value: showsPending)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy, value: chat.status)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
            viewportHeight = height
        }
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 48
        } action: { _, atBottom in
            isAtBottom = atBottom
            if atBottom { following = true }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
            guard following else { return }
            if reduceMotion || chat.status == .streaming {
                position.scrollTo(edge: .bottom)
            } else {
                withAnimation(.smooth(duration: 0.28)) { position.scrollTo(edge: .bottom) }
            }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { following = false }
            if phase == .idle { following = isAtBottom }
        }
        .overlay {
            if showsEmptyState {
                ScrollView {
                    EmptyStateView(subtitle: emptySubtitle) { showcase in
                        send(showcase.prompt)
                    }
                    .padding(.vertical, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.center)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsEmptyState)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if !following && !isAtBottom && !showsEmptyState {
                    JumpToLatestButton(isStreaming: chat.isBusy) {
                        following = true
                        withAnimation(.smooth(duration: 0.4)) { position.scrollTo(edge: .bottom) }
                    }
                    .transition(Motion.insertion(.opacity.combined(with: .scale(scale: 0.8)).combined(with: .offset(y: 8)), reduced: reduceMotion))
                }
                Composer(
                    draft: $draft,
                    isBusy: chat.isBusy,
                    flight: flight,
                    namespace: namespace,
                    focus: $composerFocused,
                    onSend: { send(draft) },
                    onStop: { chat.stop() }
                )
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .animation(Motion.spring(0.35, bounce: 0.3, reduced: reduceMotion), value: !following && !isAtBottom)
        }
        .onChange(of: chat.messages.last?.id) { _, id in
            guard let id, var current = flight, current.id == id, !current.landed else { return }
            current.landed = true
            withAnimation(.spring(duration: 0.5, bounce: 0.22)) { flight = current }
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                if flight?.id == id { flight = nil }
            }
        }
    }

    @ViewBuilder
    private func row(for message: UIMessage, turnID: String, isLast: Bool) -> some View {
        if message.role == .user {
            UserBubble(message: message, namespace: namespace)
        } else {
            AssistantMessage(
                message: message,
                name: assistantName,
                turnID: turnID,
                isLast: isLast,
                status: chat.status,
                isBusy: chat.isBusy,
                namespace: namespace,
                respond: { approvalID, approved in
                    following = true
                    Task { await chat.addToolApprovalResponse(approvalID: approvalID, approved: approved) }
                }
            )
        }
    }

    private func turnIDs(for messages: [UIMessage]) -> [String] {
        var current = "start"
        return messages.map { message in
            defer { if message.role == .user { current = message.id } }
            return current
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chat.isBusy else { return }
        let message = UIMessage(id: ChatID.generate(), role: .user, parts: [.text(trimmed)])
        flight = nil
        if !reduceMotion {
            flight = Flight(id: message.id, text: trimmed)
        }
        draft = ""
        following = true
        Task { await chat.sendMessage(message) }
    }
}

private struct JumpToLatestButton: View {
    var isStreaming: Bool
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .symbolEffect(.bounce.down, options: .repeat(.periodic(delay: 1.4)), isActive: isStreaming && !reduceMotion)
                Text(isStreaming ? "Jump to reply" : "Latest")
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

private struct ErrorBanner: View {
    var error: ChatError
    var retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(error.message)
                    .font(.subheadline)
                Button("Try again", action: retry)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
    }
}
