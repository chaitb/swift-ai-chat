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

    private var visibleMessages: [UIMessage] {
        chat.messages.filter { message in
            guard message.role != .system else { return false }
            guard let flight, !flight.landed else { return true }
            return message.id != flight.id
        }
    }

    private var showsPending: Bool {
        chat.isBusy && visibleMessages.last?.role == .user
    }

    private var showsEmptyState: Bool {
        chat.messages.isEmpty && flight == nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                    row(for: message, turnID: turnID(before: index))
                        .id(message.id)
                        .transition(message.role == .user ? .identity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 14)),
                            removal: .opacity
                        ))
                }
                if showsPending {
                    ThinkingIndicator(name: assistantName, turnID: visibleMessages.last?.id ?? "", namespace: namespace)
                        .transition(.opacity.combined(with: .offset(y: 10)))
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
            .padding(.bottom, 20)
            .frame(minHeight: viewportHeight, alignment: .bottom)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.22), value: visibleMessages.map(\.id))
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.2), value: showsPending)
            .animation(.snappy, value: chat.status)
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
            if reduceMotion {
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
                EmptyStateView(subtitle: emptySubtitle) { showcase in
                    send(showcase.prompt)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
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
                    .transition(.opacity.combined(with: .scale(scale: 0.8)).combined(with: .offset(y: 8)))
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
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .animation(.spring(duration: 0.35, bounce: 0.3), value: !following && !isAtBottom)
        }
        .onChange(of: chat.messages.last?.id) { _, id in
            guard let id, var current = flight, current.id == id, !current.landed else { return }
            current.landed = true
            withAnimation(.spring(duration: 0.55, bounce: 0.22)) { flight = current }
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                if flight?.id == id { flight = nil }
            }
        }
    }

    @ViewBuilder
    private func row(for message: UIMessage, turnID: String) -> some View {
        if message.role == .user {
            UserBubble(message: message, namespace: namespace)
        } else {
            AssistantMessage(
                message: message,
                name: assistantName,
                turnID: turnID,
                isLast: message.id == visibleMessages.last?.id,
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

    private func turnID(before index: Int) -> String {
        visibleMessages[..<index].last { $0.role == .user }?.id ?? "start"
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chat.isBusy else { return }
        let message = UIMessage(id: ChatID.generate(), role: .user, parts: [.text(trimmed)])
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .symbolEffect(.bounce.down, options: .repeat(.periodic(delay: 1.4)), isActive: isStreaming)
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
