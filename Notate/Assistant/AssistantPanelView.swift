import SwiftUI
import UIKit

enum AssistantConversationScrollPolicy {
    static func target(
        previousLatestID: UUID?,
        latestID: UUID?
    ) -> UUID? {
        guard latestID != previousLatestID else { return nil }
        return latestID
    }
}

enum AssistantComposerSubmissionPolicy {
    static func canSubmit(draft: String, isWorking: Bool) -> Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        && isWorking == false
    }
}

enum AssistantRevealMotionPolicy {
    static func usesStaticPresentation(
        reduceMotion: Bool,
        voiceOverEnabled: Bool,
        isUITesting: Bool
    ) -> Bool {
        reduceMotion || voiceOverEnabled || isUITesting
    }
}

enum AssistantLongRunningActionKind: Equatable {
    case quickSummary
    case relevantPassages

    static func preferred(
        canUseQuickResult: Bool,
        canShowRelevantPassages: Bool
    ) -> Self? {
        guard canUseQuickResult else { return nil }
        return canShowRelevantPassages ? .relevantPassages : .quickSummary
    }

    var title: String {
        switch self {
            case .quickSummary: "Use quick summary"
            case .relevantPassages: "Show relevant passages"
        }
    }

    var systemImage: String {
        switch self {
            case .quickSummary: "text.alignleft"
            case .relevantPassages: "text.magnifyingglass"
        }
    }

    var tint: Color {
        switch self {
            case .quickSummary: NotateDesign.Palette.assistantViolet
            case .relevantPassages: NotateDesign.Palette.assistantCoral
        }
    }

    var accessibilityHint: String {
        switch self {
            case .quickSummary:
            "Stops refinement and uses the verified summary already available."
            case .relevantPassages:
            "Stops refinement and shows the verified passages already available."
        }
    }

    var accessibilityIdentifier: String {
        switch self {
            case .quickSummary: "assistant.response.use-quick-result"
            case .relevantPassages: "assistant.response.show-relevant-passages"
        }
    }
}

enum AssistantTerminalAccessibilityAnnouncementPolicy {
    static func announcement(for exchange: AssistantExchange) -> String? {
        guard exchange.phase == .complete || exchange.phase == .stopped else {
            return nil
        }

        let completion: String
        switch (exchange.phase, exchange.outcome) {
            case (.complete, .content):
            completion = "Answer ready."
            case (.complete, .noResult):
            completion = "Request finished. No matching answer was found."
            case (.complete, .failure):
            completion = "Request finished."
            case (.stopped, .content):
            completion = "Response stopped. The available answer is ready."
            case (.stopped, .noResult), (.stopped, .failure):
            completion = "Response stopped."
            case (.waiting, _), (.streaming, _):
            return nil
        }

        guard exchange.sources.isEmpty == false else { return completion }
        let count = exchange.sources.count
        let noun: String
        if exchange.task == .find {
            noun = count == 1 ? "match" : "matches"
        } else {
            noun = count == 1 ? "reference" : "references"
        }
        return "\(completion) \(count) \(noun) available."
    }
}

struct AssistantPanelView: View {
    @Bindable var assistant: AssistantPresentationModel
    let surfaceColor: Color
    let onDismiss: () -> Void
    let onInsertText: (String) -> Void
    let allowsInsertion: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isComposerFocused: Bool
    @State private var conversationViewportHeight: CGFloat = 0
    @State private var settledAnswerIDs: Set<UUID>
    @State private var settledCompletionIDs: Set<UUID>
    @State private var announcedTerminalIDs: Set<UUID>

    init(
        assistant: AssistantPresentationModel,
        surfaceColor: Color,
        onDismiss: @escaping () -> Void,
        onInsertText: @escaping (String) -> Void,
        allowsInsertion: Bool = true
    ) {
        self.assistant = assistant
        self.surfaceColor = surfaceColor
        self.onDismiss = onDismiss
        self.onInsertText = onInsertText
        self.allowsInsertion = allowsInsertion
        let settledExchangeIDs = Set(
            assistant.exchanges.compactMap { exchange in
                exchange.phase == .complete || exchange.phase == .stopped
                    ? exchange.id
                    : nil
            }
        )
        _settledAnswerIDs = State(initialValue: settledExchangeIDs)
        _settledCompletionIDs = State(initialValue: settledExchangeIDs)
        _announcedTerminalIDs = State(initialValue: settledExchangeIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NotateDesign.Spacing.section) {
                        if assistant.exchanges.isEmpty {
                            emptyState
                        } else {
                            ForEach(assistant.exchanges) { exchange in
                                exchangeView(exchange)
                                    .frame(
                                        minHeight: minimumConversationHeight(for: exchange),
                                        alignment: .top
                                    )
                                    .id(exchange.id)
                            }
                        }

                        if let status = assistant.status,
                           isHoldingLatestResponse == false {
                            AssistantStatusView(status: status) { action in
                                assistant.performStatusAction(action)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("assistant-bottom")
                }
                .padding(.horizontal, NotateDesign.Spacing.content)
                .padding(.vertical, NotateDesign.Spacing.content)
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .gesture(
                TapGesture().onEnded(dismissComposerKeyboard),
                including: .gesture
            )
            .accessibilityIdentifier("assistant.conversation")
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.visibleRect.height
            } action: { _, viewportHeight in
                conversationViewportHeight = viewportHeight
            }
            .onChange(of: assistant.exchanges.last?.id) { previousID, exchangeID in
                guard let exchangeID = AssistantConversationScrollPolicy.target(
                    previousLatestID: previousID,
                    latestID: exchangeID
                ) else { return }
                Task { @MainActor in
                    // Let the new latest row acquire its viewport-sized
                    // runway before resolving the top anchor.
                    await Task.yield()
                    guard assistant.exchanges.last?.id == exchangeID else { return }
                    if AssistantRevealMotionPolicy.usesStaticPresentation(
                        reduceMotion: reduceMotion,
                        voiceOverEnabled: voiceOverEnabled,
                        isUITesting: NotateUITestLaunchConfiguration.isEnabled
                    ) {
                        proxy.scrollTo(exchangeID, anchor: .top)
                    } else {
                        withAnimation(NotateDesign.Motion.spatial) {
                            proxy.scrollTo(exchangeID, anchor: .top)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                hairline
                composer
            }
            .background(surfaceColor)
        }
        // Paint the workspace surface through every safe-area edge while the
        // content continues to respect system insets. This prevents the
        // landscape rail from exposing the host window as a white top seam.
        .background {
            surfaceColor
                .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notate for \(assistant.itemName)")
        .accessibilityIdentifier("assistant.panel")
        .onChange(of: assistant.composerFocusRequest) { _, _ in
            isComposerFocused = true
        }
        .task(id: assistant.workPhase) {
            guard let phase = assistant.workPhase,
                  UIAccessibility.isVoiceOverRunning else { return }
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            guard assistant.workPhase == phase else { return }
            let announcement = assistant.exchanges.last.map {
                activeWorkTitle(phase, for: $0)
            } ?? phase.title
            UIAccessibility.post(
                notification: .announcement,
                argument: announcement
            )
        }

private var header: some View {
    HStack(spacing: NotateDesign.Spacing.compact) {
        assistantIdentity
        Spacer(minLength: NotateDesign.Spacing.tight)
        dismissButton
    }
        .padding(.leading, NotateDesign.Spacing.content)
        .padding(.trailing, NotateDesign.Spacing.compact)
        .padding(.vertical, NotateDesign.Spacing.compact)
}

private var assistantIdentity: some View {
    HStack(spacing: NotateDesign.Spacing.compact) {
        NotateAssistantIdentityMark(size: 28)
        .accessibilityHidden(true)

        HStack(spacing: 5) {
            Text("Notate")
            .font(.subheadline.weight(.semibold))

            Text("AI")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(NotateDesign.Palette.assistantViolet)
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(
            NotateDesign.Palette.assistantViolet.opacity(0.10),
            in: Capsule()
        )
        }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Notate AI")
            .accessibilityAddTraits(.isHeader)
    }
            .layoutPriority(1)
}

private var scopeMenu: some View {
    Menu {
        ForEach(assistant.availableScopes, id: \.self) { scope in
            Button {
                assistant.scope = scope
            } label: {
                Label(assistant.displayTitle(for: scope), systemImage: scope.systemImage)
            }
        }
    } label: {
        HStack(spacing: NotateDesign.Spacing.tight) {
            Image(systemName: assistant.scope.systemImage)
            .accessibilityHidden(true)
            Text(assistant.displayTitle(for: assistant.scope))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
            .font(
        dynamicTypeSize.isAccessibilitySize
        ? .caption.weight(.medium)
        : .caption2.weight(.medium)
    )
        .foregroundStyle(.secondary)
        .padding(.horizontal, NotateDesign.Spacing.compact)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : 28)
        .notateQuietSurface(
        fillOpacity: 0.022,
        radius: NotateDesign.Radius.option
    )
        // Keep the pill visually compact while preserving a comfortable
        // menu target for touch, pointer, and assistive input.
        .frame(minHeight: NotateDesign.Control.minimumHitTarget, alignment: .leading)
        .contentShape(Rectangle())
    }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Assistant scope, \(assistant.displayTitle(for: assistant.scope))")
        .accessibilityIdentifier("assistant.scope")
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(
                    width: NotateDesign.Control.minimumHitTarget,
                    height: NotateDesign.Control.minimumHitTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Close Notate")
        .accessibilityIdentifier("assistant.dismiss")
    }

private var emptyState: some View {
    VStack(alignment: .leading, spacing: NotateDesign.Spacing.content) {
        VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
            NotateAssistantIdentityMark(size: 36)
            .accessibilityHidden(true)

            Text("Think with your notes")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("assistant.empty-state.title")

            Text("Start with this page, or follow an idea across your notebook.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        }

        VStack(spacing: 0) {
            suggestionButton(
            "Distill this note",
            icon: "text.alignleft",
            tint: NotateDesign.Palette.assistantViolet
        )

            Rectangle()
            .fill(.primary.opacity(hairlineOpacity * 0.72))
            .frame(height: hairlineWidth)
            .padding(.leading, 42)
            .accessibilityHidden(true)

            suggestionButton(
            "Find a thread in my notebook",
            icon: "text.magnifyingglass",
            tint: NotateDesign.Palette.assistantCoral
        )
        }
            .notateQuietSurface(fillOpacity: 0.018)
    }
            .padding(.vertical, 4)
            .accessibilityIdentifier("assistant.empty-state")
}

    private func suggestionButton(
        _ title: String,
        icon: String,
        tint: Color
    ) -> some View {
        Button {
            assistant.draft = title
            assistant.focusComposer()
        } label: {
            HStack(spacing: NotateDesign.Spacing.compact) {
                AssistantSuggestionGlyph(
                    systemImage: icon,
                    tint: tint
                )
                .accessibilityHidden(true)

                Text(title)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: NotateDesign.Spacing.compact)

                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NotateDesign.Spacing.control)
            .frame(minHeight: NotateDesign.Control.minimumHitTarget)
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private func exchangeView(
        _ exchange: AssistantExchange
    ) -> some View {
        let responsePresentation = assistant.responsePresentation?.exchangeID == exchange.id
            ? assistant.responsePresentation
            : nil
        let isHoldingPreliminaryResult = assistant.shouldHoldPreliminaryResult(
            for: exchange.id
        )
        let isHoldingResponse = (
            responsePresentation != nil || isHoldingPreliminaryResult
        )
        && exchange.phase != .stopped

        return VStack(alignment: .leading, spacing: NotateDesign.Spacing.control) {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 40)

            Text(exchange.question)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Color.primary.opacity(0.055),
                    in: .rect(cornerRadius: 15)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(
                            .primary.opacity(hairlineOpacity * 0.72),
                            lineWidth: hairlineWidth
                        )
                }
        }
        .padding(.vertical, NotateDesign.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(exchange.question)")
        .accessibilityIdentifier("assistant.user-message.\(exchange.id)")

        VStack(alignment: .leading, spacing: NotateDesign.Spacing.control) {
            HStack(spacing: NotateDesign.Spacing.compact) {
                responseMark(
                    for: exchange,
                    isHoldingResponse: isHoldingResponse
                )

                if isHoldingResponse == false,
                   let summaryLabel = exchange.summaryProvenance?.title
                   ?? exchange.preliminaryResult?.title {
                    Text(summaryLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(NotateDesign.Palette.assistantViolet)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .frame(minHeight: 22)
                        .background(
                            NotateDesign.Palette.assistantViolet.opacity(0.10),
                            in: Capsule()
                        )
                        .accessibilityIdentifier(
                            "assistant.response.badge.\(exchange.id)"
                        )
                        .accessibilityIdentifier("assistant.response.stop.\(exchange.id)")
                }
            }

            responseBody(
                exchange,
                isHoldingResponse: isHoldingResponse,
                onAnswerSettled: {
                    settledAnswerIDs.insert(exchange.id)
                }
            )

            if let kind = longRunningActionKind(for: exchange) {
                AssistantLongRunningActionButton(kind: kind) {
                    switch kind {
                    case .quickSummary:
                        assistant.useQuickResult()
                    case .relevantPassages:
                        assistant.showRelevantPassages()
                    }
                }
            }

            if isHoldingResponse == false {
                AssistantCompletionSequenceView(
                    exchange: exchange,
                    surfaceColor: surfaceColor,
                    receipt: completionReceipt(for: exchange),
                    referenceKind: referenceSectionKind(for: exchange),
                    openSource: { source in
                        dismissComposerKeyboard()
                        assistant.openSource(source)
                    },
                    insertText: onInsertText,
                    allowsInsertion: allowsInsertion,
                    submitFollowUp: { prompt in
                        dismissComposerKeyboard()
                        assistant.requestMode = .ask
                        assistant.submitSuggestion(prompt)
                    },
                    canSubmitFollowUp: assistant.isWorking == false,
                    answerIsSettled: settledAnswerIDs.contains(exchange.id),
                    shouldAnimateCompletion: settledCompletionIDs.contains(exchange.id) == false,
                    onRevealCompleted: {
                        settledCompletionIDs.insert(exchange.id)
                        announceTerminalCompletionIfNeeded(for: exchange)
                    }
                )
            }

            if exchange.phase == .stopped,
               exchange.outcome.presentsCompletionAffordances == false
               || settledCompletionIDs.contains(exchange.id) {
                Button("Retry") {
                    assistant.requestMode = exchange.mode
                    assistant.submitSuggestion(exchange.question)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("assistant.response.retry.\(exchange.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.response.\(exchange.id)")

        hairline
            .padding(.top, NotateDesign.Spacing.tight)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("assistant.exchange.\(exchange.id)")
    }

    private func minimumConversationHeight(
        for exchange: AssistantExchange
    ) -> CGFloat? {
        guard assistant.exchanges.last?.id == exchange.id,
              conversationViewportHeight > 0 else { return nil }
        return max(
            0,
            conversationViewportHeight - NotateDesign.Spacing.content * 2
        )
    }

    private func longRunningActionKind(
        for exchange: AssistantExchange
    ) -> AssistantLongRunningActionKind? {
        guard assistant.showsLongRunningActions,
              assistant.exchanges.last?.id == exchange.id,
              exchange.phase == .waiting || exchange.phase == .streaming else {
            return nil
        }
        return AssistantLongRunningActionKind.preferred(
            canUseQuickResult: assistant.canUseQuickResult,
            canShowRelevantPassages: assistant.canShowRelevantPassages
        )
    }

    @ViewBuilder
    private func responseMark(
        for exchange: AssistantExchange,
        isHoldingResponse: Bool
    ) -> some View {
        let showsThinking = isHoldingResponse
            || exchange.phase == .waiting
            || (exchange.phase == .streaming
                && exchange.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        ZStack {
            if showsThinking {
                AssistantThinkingMark()
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                NotateAssistantIdentityMark(size: 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(width: 24, height: 24)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.22),
            value: showsThinking
        )
        .accessibilityHidden(true)
    }

    private func processingLabel(
        for exchange: AssistantExchange,
        responsePresentation: AssistantResponsePresentation?
    ) -> String? {
        if let responsePresentation, exchange.phase == .stopped {
            return responsePresentation.title
        }
        guard assistant.showsProgress else { return nil }
        switch exchange.phase {
        case .waiting, .streaming:
            if assistant.isTakingLonger {
                return "Still working on this iPad."
            }
            return assistant.workPhase.map { activeWorkTitle($0, for: exchange) }
            ?? (exchange.mode == .find ? "Getting the relevant details…" : "Reading your note…")
        case .complete, .stopped:
            return nil
        }
    }

    @ViewBuilder
    private func responseBody(
        _ exchange: AssistantExchange,
        isHoldingResponse: Bool,
        onAnswerSettled: @escaping () -> Void
    ) -> some View {
        if isHoldingResponse {
            AssistantResponseSkeleton()
        } else {
            switch exchange.phase {
            case .waiting:
                if assistant.showsProgress {
                    AssistantResponseSkeleton()
                }

            case .streaming, .complete, .stopped:
                if exchange.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AssistantResponseSkeleton()
                } else {
                    AssistantResponseRevealText(
                        text: exchange.answer,
                        isStreaming: exchange.phase == .streaming
                            && exchange.preliminaryResult == nil,
                        isFinal: exchange.phase == .complete
                            || exchange.phase == .stopped,
                        animatesEntrance: settledAnswerIDs.contains(exchange.id) == false,
                        onEntranceCompleted: onAnswerSettled
                    )
                    .accessibilityIdentifier(
                        exchange.phase == .streaming
                            ? "assistant.response.processing.\(exchange.id)"
                            : "assistant.response.answer.\(exchange.id)"
                    )
                }
            }
        }
    }
    private func activeWorkTitle(
        _ phase: AssistantWorkPhase,
        for exchange: AssistantExchange
    ) -> String {
        switch phase {
        case .readingNote:
            switch exchange.scope {
            case .page: return "Checking the latest page…"
            case .library: return "Searching this iPad…"
            case .item:
                return "Checking the latest \((exchange.scopeTitle ?? "notebook").lowercased())…"
            case nil: return phase.title
            }
        case .gettingRelevantDetails:
            return exchange.scope == .library
                ? "Searching this iPad…"
                : "Getting the relevant details…"
        case .thinkingThroughNotes:
            switch exchange.task {
            case .answer: return "Writing a grounded answer…"
            case .explain: return "Building an explanation from your note…"
            case .study: return "Preparing study material…"
            case .summarize: return "Writing the summary…"
            case .find, nil: return phase.title
            }
        case .finishingUp:
            return "Checking sources and formatting…"
        case .writingSummary, .summarizingSection:
            return phase.title
        }
    }

    private func completionReceipt(for exchange: AssistantExchange) -> String? {
        guard exchange.outcome.presentsCompletionAffordances,
              exchange.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let scope = exchange.scopeTitle ?? exchange.scope?.displayTitle
        if exchange.task == .find {
            let matches = exchange.sources.count
            let result = "Found \(matches) \(matches == 1 ? "match" : "matches")"
            return [result, scope, "On device"].compactMap { $0 }.joined(separator: " · ")
        }
        if exchange.task == .summarize {
            let readScope = "Read current \((scope ?? "note").lowercased())"
            return "\(readScope) · On device"
        }
        if exchange.sources.isEmpty == false {
            let count = exchange.sources.count
            let grounded = "Grounded in \(count) \(count == 1 ? "reference" : "references")"
            return [grounded, scope, "On device"].compactMap { $0 }.joined(separator: " · ")
        }
        return exchange.isGeneralKnowledge ? "General knowledge · On device" : "Completed on device"
    }

    private func referenceSectionKind(
        for exchange: AssistantExchange
    ) -> AssistantReferenceSectionKind {
        if exchange.task == .find { return .matches }
        if exchange.preliminaryResult == .relevantPassages { return .relevantPassages }
        return .references
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
            VStack(alignment: .leading, spacing: 0) {
                scopeMenu
                HStack(alignment: .bottom, spacing: NotateDesign.Spacing.tight) {
                    TextField(
                        "Ask or find in your notes",
                        text: $assistant.draft,
                        axis: .vertical
                    )
                    .lineLimit(1...5)
                    .focused($isComposerFocused)
                    .submitLabel(.send)
                    .onSubmit(submitComposer)
                    .font(.callout)
                    .frame(minHeight: NotateDesign.Control.minimumHitTarget)
                    .accessibilityLabel("Ask or find in your notes")
                    .accessibilityIdentifier("assistant.composer")

                    Button(action: submitComposer) {
                        AssistantSubmitButtonLabel(
                            systemImage: "arrow.up",
                            isEnabled: canSubmit
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(canSubmit == false)
                    .hoverEffect(.highlight)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("assistant.submit")
                }
            }
            .padding(.leading, NotateDesign.Spacing.control)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .notateQuietSurface(
                fillOpacity: 0.025,
                radius: NotateDesign.Radius.control
            )
            .overlay {
                Group {
                    if showsAssistantActivity {
                        AssistantSpectrumRim(cornerRadius: NotateDesign.Radius.control)
                            .transition(.opacity)
                    } else {
                        RoundedRectangle(
                            cornerRadius: NotateDesign.Radius.control,
                            style: .continuous
                        )
                        .stroke(
                            isComposerFocused
                                ? Color.primary.opacity(
                                    contrast == .increased ? 0.44 : 0.22
                                )
                                : Color.clear,
                            lineWidth: hairlineWidth
                        )
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.18),
                    value: showsAssistantActivity
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("assistant.composer.surface")
        }
        .padding(.horizontal, NotateDesign.Spacing.content)
        .padding(.top, NotateDesign.Spacing.compact)
        .padding(.bottom, NotateDesign.Spacing.control)
        .background(surfaceColor)
    }

    private var canSubmit: Bool {
        AssistantComposerSubmissionPolicy.canSubmit(
            draft: assistant.draft,
            isWorking: assistant.isWorking
        )
    }

    private var showsAssistantActivity: Bool {
        assistant.isWorking
    }

    private var isHoldingLatestResponse: Bool {
        guard let exchange = assistant.exchanges.last else { return false }
        let holdsPresentation = assistant.responsePresentation?.exchangeID == exchange.id
        let holdsPreliminaryResult = assistant.shouldHoldPreliminaryResult(
            for: exchange.id
        )
        let isRevealingCompletion = exchange.phase == .complete
            && settledCompletionIDs.contains(exchange.id) == false
        return (holdsPresentation || holdsPreliminaryResult || isRevealingCompletion)
            && exchange.phase != .stopped
    }

    private var hairline: some View {
        Rectangle()
            .fill(.primary.opacity(hairlineOpacity))
            .frame(height: hairlineWidth)
            .accessibilityHidden(true)
    }

    private func submitComposer() {
        guard canSubmit else { return }
        dismissComposerKeyboard()
        assistant.submitDraftAutomatically()
    }

    private func dismissComposerKeyboard() {
        isComposerFocused = false
    }

    private func announceTerminalCompletionIfNeeded(
        for exchange: AssistantExchange
    ) {
        guard voiceOverEnabled,
              announcedTerminalIDs.insert(exchange.id).inserted,
              let announcement = AssistantTerminalAccessibilityAnnouncementPolicy
                .announcement(for: exchange) else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: announcement
        )
    }

    private var hairlineOpacity: Double {
        NotateDesign.Hairline.opacity(for: contrast)
    }

    private var hairlineWidth: CGFloat {
        NotateDesign.Hairline.width(for: contrast)
    }

    private struct AssistantSuggestionGlyph: View {
        let systemImage: String
        let tint: Color

        var body: some View {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.11))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tint.opacity(0.15), lineWidth: 0.75)
                }
        }
    }

    private struct AssistantLongRunningActionButton: View {
        let kind: AssistantLongRunningActionKind
        let action: () -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button(action: action) {
                HStack(spacing: NotateDesign.Spacing.compact) {
                    AssistantSuggestionGlyph(
                        systemImage: kind.systemImage,
                        tint: kind.tint
                    )
                    .accessibilityHidden(true)

                    Text(kind.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.82))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: NotateDesign.Spacing.compact)

                    Image(systemName: "arrow.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, NotateDesign.Spacing.control)
                .frame(
                    maxWidth: .infinity,
                    minHeight: NotateDesign.Control.minimumHitTarget,
                    alignment: .leading
                )
                .contentShape(.rect(cornerRadius: NotateDesign.Radius.option))
                .notateQuietSurface(fillOpacity: 0.018)
            }
            .buttonStyle(NotatePressButtonStyle(reduceMotion: reduceMotion))
            .hoverEffect(.highlight)
            .accessibilityHint(kind.accessibilityHint)
            .accessibilityIdentifier(kind.accessibilityIdentifier)
        }
    }

    private struct AssistantStatusView: View {
        let status: AssistantStatus
        let performAction: (AssistantStatusAction) -> Void

        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        @ViewBuilder
        var body: some View {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
                    statusMessage

                    if let action = status.action {
                        actionButton(action)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .statusSurface(identifier: "assistant.status")
            } else {
                HStack(alignment: .top, spacing: NotateDesign.Spacing.compact) {
                    statusMessage

                    Spacer(minLength: 0)

                    if let action = status.action {
                        actionButton(action)
                    }
                }
                .statusSurface(identifier: "assistant.status")
            }
        }

        private var statusMessage: some View {
            HStack(alignment: .top, spacing: NotateDesign.Spacing.compact) {
                Image(systemName: status.severity.systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.severity.tint)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func actionButton(_ action: AssistantStatusAction) -> some View {
            Button(action.title) {
                performAction(action)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .notateMinimumHitTarget()
        }
    }

    private extension View {
        func statusSurface(identifier: String) -> some View {
            padding(.horizontal, 10)
                .padding(.vertical, NotateDesign.Spacing.compact)
                .notateQuietSurface(fillOpacity: 0.018)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
        }
    }

private extension AssistantStatusSeverity {
    var systemImage: String {
        switch self {
            case .information: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
            case .information: .secondary
            case .warning: .orange
            case .error: .red
        }
    }
}

private extension AssistantStatusAction {
    var title: String {
        switch self {
            case .retry: "Retry"
            case .chooseNotebook: "Use notebook"
        }
    }
}

    private struct AssistantSubmitButtonLabel: View {
        let systemImage: String
        let isEnabled: Bool

        var body: some View {
            ZStack {
                Circle()
                    .fill(
                        isEnabled
                            ? Color.primary.opacity(0.90)
                            : Color.primary.opacity(0.055)
                    )
                    .frame(width: 36, height: 36)
                    .frame(width: 66, height: 66)

                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(
                        isEnabled
                            ? Color(uiColor: .systemBackground)
                            : Color.primary.opacity(0.34)
                    )
            }
            .frame(
                width: NotateDesign.Control.minimumHitTarget,
                height: NotateDesign.Control.minimumHitTarget
            )
            .contentShape(Circle())
        }
    }

    private enum AssistantReferenceSectionKind {
        case references
        case matches
        case relevantPassages

        func countLabel(_ count: Int) -> String {
            switch self {
            case .references:
                return count == 1 ? "1 reference" : "\(count) references"
            case .matches:
                return count == 1 ? "1 match" : "\(count) matches"
            case .relevantPassages:
                return count == 1 ? "1 relevant passage" : "\(count) relevant passages"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .references: "References"
            case .matches: "Matches"
            case .relevantPassages: "Relevant passages"
            }
        }
    }

enum AssistantSourceRevealPolicy {
    static let rowInterval: Duration = .milliseconds(48)
    static let rowAnimationDuration: TimeInterval = 0.22
}

private struct AssistantReferencesView: View {
    let sources: [AssistantSearchResult]
    let surfaceColor: Color
    let kind: AssistantReferenceSectionKind
    let startsExpanded: Bool
    let openSource: (AssistantSourceAnchor) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isExpanded = false
    @State private var visibleSourceCount = 0

        init(
            sources: [AssistantSearchResult],
            surfaceColor: Color,
            kind: AssistantReferenceSectionKind = .references,
            startsExpanded: Bool = false,
            openSource: @escaping (AssistantSourceAnchor) -> Void
        ) {
            self.sources = sources
            self.surfaceColor = surfaceColor
            self.kind = kind
            self.startsExpanded = startsExpanded
            self.openSource = openSource
            _isExpanded = State(initialValue: startsExpanded)
        }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                let willExpand = isExpanded == false
                if willExpand, usesStaticReveal {
                    visibleSourceCount = sources.count
                }
                withAnimation(usesStaticReveal ? nil : NotateDesign.Motion.content) {
                    isExpanded = willExpand
                }
            } label: {
                HStack(spacing: 8) {
                    Text(referenceCountLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                    sourceGlyphs

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
                }
                    .padding(.horizontal, NotateDesign.Spacing.control)
                    .frame(minHeight: NotateDesign.Control.minimumHitTarget)
                    .contentShape(Rectangle())
            }
                    .buttonStyle(.plain)
                    .accessibilityLabel(kind.accessibilityLabel)
                    .accessibilityValue(
            "\(sources.count) items, \(isExpanded ? "expanded" : "collapsed")"
        )
            .accessibilityHint(
            isExpanded
            ? "Collapses \(kind.accessibilityLabel.lowercased())"
            : "Shows \(kind.accessibilityLabel.lowercased())"
        )
            .accessibilityIdentifier("assistant.references.toggle")

            if isExpanded {
                referenceDivider(inset: 0)

                ForEach(
                Array(sources.prefix(visibleSourceCount).enumerated()),
                id: \.element.id
            ) { index, source in
                    referenceRow(source)
                    .transition(
                    .offset(y: -6)
                    .combined(with: .opacity)
                )

                    if index < displayedSourceCount - 1 {
                        referenceDivider(inset: 40)
                        .transition(.opacity)
                    }
                }
            }
        }
                        .background(.primary.opacity(0.022))
                        .clipShape(.rect(cornerRadius: NotateDesign.Radius.option))
                        .overlay {
            RoundedRectangle(cornerRadius: NotateDesign.Radius.option, style: .continuous)
            .stroke(
            .primary.opacity(
            NotateDesign.Hairline.opacity(for: contrast, subtle: true)
        ),
            lineWidth: hairlineWidth
        )
        }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("assistant.references")
            .task(id: sourceRevealIdentity) {
            await revealSourcesIfNeeded()
        }
    }

    private var usesStaticReveal: Bool {
        AssistantSourceRevealPolicy.usesStaticPresentation(
        reduceMotion: reduceMotion,
        voiceOverEnabled: voiceOverEnabled,
        uiTesting: NotateUITestLaunchConfiguration.isEnabled
    )
    }

    private var displayedSourceCount: Int {
        min(visibleSourceCount, sources.count)
    }

    private var sourceRevealIdentity: String {
        let sourceIdentity = sources.map(\.id).joined(separator: ",")
        return "\(isExpanded):\(sourceIdentity):\(visibleSourceCount)"
    }

    /// Expanding a bounded reference set reveals its rows from top to bottom.
    /// This animation is presentation only; source retrieval and publication are
    /// never enabled and are never held back by the stagger.
    @MainActor
    private func revealSourcesIfNeeded() async {
        guard isExpanded else {
            visibleSourceCount = 0
            return
        }
        guard sources.isEmpty == false else {
            visibleSourceCount = 0
            return
        }
        // The completion sequence animates an initially expanded reference
        // section as one native stage. Manual expansion keeps the lighter row
        // cascade below, where it cannot delay actions or follow-ups.
        guard startsExpanded == false else {
            visibleSourceCount = sources.count
            return
        }
        guard usesStaticReveal == false else {
            visibleSourceCount = sources.count
            return
        }

        visibleSourceCount = 0
        for count in 1...sources.count {
            if count > 1 {
                do {
                    try await Task.sleep(
                    for: AssistantSourceRevealPolicy.rowInterval
                )
                } catch {
                    return
                }
            }
            guard Task.isCancelled == false, isExpanded else { return }
            withAnimation(
            .smooth(duration: AssistantSourceRevealPolicy.rowAnimationDuration)
        ) {
                visibleSourceCount = count
            }
        }
    }

    private var sourceGlyphs: some View {
        HStack(spacing: -4) {
            ForEach(Array(sources.prefix(3))) { source in
                Image(systemName: source.anchor.kind.systemImage)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(surfaceColor, in: Circle())
                .overlay {
                    Circle()
                    .stroke(
                    .primary.opacity(hairlineOpacity),
                    lineWidth: hairlineWidth
                )
                }
            }
        }
                    .accessibilityHidden(true)
    }

    private func referenceRow(_ source: AssistantSearchResult) -> some View {
        Button {
            openSource(source.anchor)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: source.anchor.kind.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.anchor.locationTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                    if source.displaySnippet.isEmpty == false {
                        Text(verbatim: source.displaySnippet)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 4)
            }
                .padding(.horizontal, NotateDesign.Spacing.control)
                .padding(.vertical, 7)
                .frame(minHeight: NotateDesign.Control.minimumHitTarget)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(source.anchor.locationTitle)
                .accessibilityValue(
        source.displaySnippet.isEmpty
        ? source.anchor.kind.accessibilityTitle
        : "\(source.anchor.kind.accessibilityTitle). \(source.displaySnippet)"
    )
        .accessibilityHint("Opens this reference in the note")
        .accessibilityIdentifier("assistant.reference.\(source.id)")
    }

    private func referenceDivider(inset: CGFloat) -> some View {
        Rectangle()
        .fill(.primary.opacity(hairlineOpacity * 0.72))
        .frame(height: hairlineWidth)
        .padding(.leading, inset)
        .accessibilityHidden(true)
    }

    private var referenceCountLabel: String {
        kind.countLabel(sources.count)
    }

    private var hairlineOpacity: Double {
        NotateDesign.Hairline.opacity(for: contrast)
    }

    private var hairlineWidth: CGFloat {
        NotateDesign.Hairline.width(for: contrast)
    }
}

enum AssistantCompletionRevealStage: Int, Equatable {
    case answer
    case receipt
    case references
    case actions
    case followUps

    static func sequence(
    hasReceipt: Bool,
    hasReferences: Bool,
    showsActions: Bool,
    hasFollowUps: Bool
) -> [AssistantCompletionRevealStage] {
        var stages: [AssistantCompletionRevealStage] = []
        if hasReceipt { stages.append(.receipt) }
        if hasReferences { stages.append(.references) }
        if showsActions { stages.append(.actions) }
        if hasFollowUps { stages.append(.followUps) }
        return stages
    }
}

private struct AssistantCompletionRevealTrigger: Hashable {
    let exchangeID: UUID
    let isTerminal: Bool
    let answerIsSettled: Bool
    let followUps: [String]
}

/// Reveals the completed response as one downward-moving sequence instead of
/// inserting references, actions, and follow-ups in a single layout jump.
private struct AssistantCompletionSequenceView: View {
    let exchange: AssistantExchange
    let surfaceColor: Color
    let receipt: String?
    let referenceKind: AssistantReferenceSectionKind
    let openSource: (AssistantSourceAnchor) -> Void
    let insertText: (String) -> Void
    let allowsInsertion: Bool
    let submitFollowUp: (String) -> Void
    let canSubmitFollowUp: Bool
    let answerIsSettled: Bool
    let shouldAnimateCompletion: Bool
    let onRevealCompleted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var revealStage: AssistantCompletionRevealStage
    @State private var followUpsAreVisible: Bool

        init(
            exchange: AssistantExchange,
            surfaceColor: Color,
            receipt: String?,
            referenceKind: AssistantReferenceSectionKind,
            openSource: @escaping (AssistantSourceAnchor) -> Void,
            insertText: @escaping (String) -> Void,
            allowsInsertion: Bool,
            submitFollowUp: @escaping (String) -> Void,
            canSubmitFollowUp: Bool,
            answerIsSettled: Bool,
            shouldAnimateCompletion: Bool,
            onRevealCompleted: @escaping () -> Void
        ) {
            self.exchange = exchange
            self.surfaceColor = surfaceColor
            self.receipt = receipt
            self.referenceKind = referenceKind
            self.openSource = openSource
            self.insertText = insertText
            self.allowsInsertion = allowsInsertion
            self.submitFollowUp = submitFollowUp
            self.canSubmitFollowUp = canSubmitFollowUp
            self.answerIsSettled = answerIsSettled
            self.shouldAnimateCompletion = shouldAnimateCompletion
            self.onRevealCompleted = onRevealCompleted
            // A cache hit can complete before SwiftUI draws the pending exchange.
            // New exchange IDs therefore begin at the answer even when already
            // complete, while settled transcript rows remain fully visible when a
            // LazyVStack recycles them or the panel is reopened.
            _revealStage = State(
                initialValue: shouldAnimateCompletion ? .answer : .followUps
            )
            _followUpsAreVisible = State(
                initialValue: shouldAnimateCompletion == false
            )
        }

    var body: some View {
        Group {
            if (exchange.phase == .complete || exchange.phase == .stopped),
            answerIsSettled {
                VStack(alignment: .leading, spacing: NotateDesign.Spacing.control) {
                    if let receipt,
                    isVisible(.receipt) {
                        Label(receipt, systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(receipt)
                        .accessibilityIdentifier(
                        "assistant.response.receipt.\(exchange.id)"
                    )
                        .transition(completionTransition)
                    }

                    if exchange.sources.isEmpty == false,
                    isVisible(.references) {
                        AssistantReferencesView(
                        sources: exchange.sources,
                        surfaceColor: surfaceColor,
                        kind: referenceKind,
                        startsExpanded: referencesStartExpanded,
                        openSource: openSource
                    )
                        .transition(completionTransition)
                    }

                    if presentsResponseActions,
                    isVisible(.actions) {
                        responseActions
                        .transition(completionTransition)
                    }

                    if exchange.outcome.presentsCompletionAffordances,
                    exchange.followUps.isEmpty == false,
                    followUpsAreVisible {
                        followUpSuggestions
                        .transition(completionTransition)
                    }
                }
            }
        }
                        .task(id: revealTrigger) {
            await revealCompletionIfNeeded()
        }
    }

    private var revealTrigger: AssistantCompletionRevealTrigger {
        AssistantCompletionRevealTrigger(
        exchangeID: exchange.id,
        isTerminal: exchange.phase == .complete || exchange.phase == .stopped,
        answerIsSettled: answerIsSettled,
        followUps: exchange.followUps
    )
    }

    private var referencesStartExpanded: Bool {
        exchange.task == .find
        || exchange.preliminaryResult == .relevantPassages
    }

    private var presentsResponseActions: Bool {
        exchange.outcome.presentsCompletionAffordances
        && exchange.task != .find
        && exchange.preliminaryResult != .relevantPassages
    }
}
private var responseActions: some View {
    HStack(spacing: 0) {
        Button {
            UIPasteboard.general.string = exchange.answer
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
            .frame(minHeight: NotateDesign.Control.minimumHitTarget)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)

        if allowsInsertion {
            Rectangle()
            .fill(.primary.opacity(hairlineOpacity))
            .frame(width: hairlineWidth, height: 20)
            .accessibilityHidden(true)

            Button {
                insertText(exchange.answer)
            } label: {
                Label("Insert", systemImage: "text.badge.plus")
                .frame(minHeight: NotateDesign.Control.minimumHitTarget)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
        }
    }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.76))
                .fixedSize(horizontal: true, vertical: false)
                .notateQuietSurface(fillOpacity: 0.018)
                .accessibilityIdentifier("assistant.exchange.actions.\(exchange.id)")
}

private var followUpSuggestions: some View {
    VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
        Text("Continue")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)

        VStack(spacing: 0) {
            ForEach(
            Array(exchange.followUps.enumerated()),
            id: \.element
        ) { index, prompt in
                Button {
                    submitFollowUp(prompt)
                } label: {
                    HStack(spacing: NotateDesign.Spacing.compact) {
                        Text(prompt)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                        Spacer(minLength: NotateDesign.Spacing.compact)

                        Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    }
                        .padding(.horizontal, 10)
                        .frame(
                    maxWidth: .infinity,
                    minHeight: NotateDesign.Control.minimumHitTarget,
                    alignment: .leading
                )
                    .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .disabled(canSubmitFollowUp == false)

                if index < exchange.followUps.count - 1 {
                    Rectangle()
                    .fill(.primary.opacity(hairlineOpacity * 0.72))
                    .frame(height: hairlineWidth)
                    .padding(.leading, 10)
                    .accessibilityHidden(true)
                }
            }
        }
                    .notateQuietSurface(fillOpacity: 0.018)
    }
}

private var completionTransition: AnyTransition {
.offset(y: -8).combined(with: .opacity)
}

private var usesStaticReveal: Bool {
    AssistantRevealMotionPolicy.usesStaticPresentation(
    reduceMotion: reduceMotion,
    voiceOverEnabled: voiceOverEnabled,
    isUITesting: NotateUITestLaunchConfiguration.isEnabled
)
}

private func isVisible(_ stage: AssistantCompletionRevealStage) -> Bool {
    revealStage.rawValue >= stage.rawValue
}

@MainActor
private func revealCompletionIfNeeded() async {
    guard exchange.phase == .complete || exchange.phase == .stopped,
    answerIsSettled else { return }
    // Suggestions are deliberately opportunistic and may finish after the
    // answer/references sequence. Keep them hidden until their own motion
    // transaction so a late local result never pops into a settled row.
    if revealStage == .followUps,
    exchange.outcome.presentsCompletionAffordances,
    exchange.followUps.isEmpty == false,
    followUpsAreVisible == false {
        await reveal(.followUps)
        return
    }
    guard shouldAnimateCompletion else {
        revealStage = .followUps
        followUpsAreVisible = true
        return
    }
    guard revealStage != .followUps else { return }

    let stages = AssistantCompletionRevealStage.sequence(
    hasReceipt: receipt != nil,
    hasReferences: exchange.sources.isEmpty == false,
    showsActions: presentsResponseActions,
    hasFollowUps: exchange.outcome.presentsCompletionAffordances
    && exchange.followUps.isEmpty == false
)

    for stage in stages {
        guard Task.isCancelled == false else { return }
        guard stage.rawValue > revealStage.rawValue else { continue }
        await reveal(stage)
        guard Task.isCancelled == false else { return }
        if usesStaticReveal == false {
            do {
                try await Task.sleep(for: .milliseconds(72))
            } catch {
                return
            }
        }
    }

    // `.followUps` also acts as the terminal reveal marker when an answer
    // has no suggestions. This prevents a reconstructed task from
    // replaying references and actions after their first reveal.
    if revealStage != .followUps {
        revealStage = .followUps
    }
    onRevealCompleted()
}

@MainActor
private func reveal(_ stage: AssistantCompletionRevealStage) async {
    guard usesStaticReveal == false else {
        revealStage = stage
        if stage == .followUps {
            followUpsAreVisible = true
        }
        await Task.yield()
        return
    }

    await withCheckedContinuation { continuation in
        withAnimation(
        NotateDesign.Motion.content,
        completionCriteria: .logicallyComplete
    ) {
            revealStage = stage
            if stage == .followUps {
                followUpsAreVisible = true
            }
        } completion: {
            continuation.resume()
        }
    }
}

private var hairlineOpacity: Double {
    NotateDesign.Hairline.opacity(for: contrast)
}

private var hairlineWidth: CGFloat {
    NotateDesign.Hairline.width(for: contrast)
}

/// Gives the retrieval/model handoff a stable visual footprint so the answer
/// never flashes through an empty white block while the first tokens arrive.
private struct AssistantResponseSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usesStaticPresentation: Bool {
        reduceMotion || NotateUITestLaunchConfiguration.isEnabled
    }

    @ViewBuilder
    var body: some View {
        if usesStaticPresentation {
            placeholder(phase: 0.45)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 15)) { timeline in
                placeholder(
                phase: timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.8) / 1.8
            )
            }
        }
    }

    private func placeholder(phase: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            placeholderLine(trailingSpace: 8, energy: energy(for: 0, phase: phase))
            placeholderLine(trailingSpace: 42, energy: energy(for: 1, phase: phase))
            placeholderLine(trailingSpace: 92, energy: energy(for: 2, phase: phase))
        }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .accessibilityHidden(true)
    }

    private func placeholderLine(trailingSpace: CGFloat, energy: Double) -> some View {
        HStack(spacing: 0) {
            Capsule()
            .fill(
            LinearGradient(
            colors: [
            Color.primary.opacity(0.055),
            NotateDesign.Palette.assistantCyan.opacity(0.11 + energy * 0.09),
            NotateDesign.Palette.assistantViolet.opacity(0.10 + energy * 0.09),
            Color.primary.opacity(0.045),
        ],
            startPoint: .leading,
            endPoint: .trailing
        )
        )
            .frame(maxWidth: .infinity)

            Spacer(minLength: trailingSpace)
            .frame(width: trailingSpace)
        }
            .frame(height: 6)
            .opacity(0.72 + energy * 0.28)
    }

    private func energy(for line: Double, phase: Double) -> Double {
        (sin((phase + line * 0.18) * .pi * 2) + 1) / 2
    }
}

/// Display-linked motion for cumulative model snapshots. The entire latest
/// snapshot is laid out immediately, while a continuous glyph renderer exposes
/// it at a controlled velocity. No animation frame mutates the String itself.
enum AssistantResponseRevealPolicy {
    /// A brief composited entrance is enough; text pacing is handled by the
    /// display-synchronized glyph renderer below.
    static let entranceDuration: TimeInterval = 0.22
}

private enum AssistantContinuousRevealMetrics {
    static let maximumAnnotatedCharacterCount = 512
    static let maximumTerminalHandoffCharacterCount = 128
}

struct AssistantTerminalRevealHandoff: Equatable, Sendable {
    let bridgeText: String
    let authoritativePrefix: String
}

struct AssistantContinuousStreamReveal: Equatable, Sendable {
    private static let minimumFadeWidth = 4.0
    private static let maximumFadeWidth = 24.0
    private static let maximumFinalAnimatedCharacters = 64.0
    private static let maximumColdFinalAnimatedCharacters = 480.0
    private static let finalFadeWidth = 12.0
    private static let finalSettleHorizon = 0.24
    private static let coldFinalMinimumHorizon = 0.55
    private static let coldFinalMaximumHorizon = 2.40
    private static let coldFinalPreferredCharactersPerSecond = 100.0
    private static let fadeWidthTransitionDuration = 0.10
    private static let streamingTailSettleDuration = 0.10

    private(set) var text = ""
    private(set) var startProgress = 0.0
    private(set) var targetProgress = 0.0
    private(set) var committedProgress = 0.0
    private(set) var startedAt = 0.0
    private(set) var charactersPerSecond = 52.0
    private(set) var startFadeWidth = 5.2
    private(set) var targetFadeWidth = 5.2
    private(set) var fadeStartedAt = 0.0
    // When a provider revises an already-visible sentence, keep that stable
    // base while continuing with later semantic units from the authoritative
    // stream. The corrected terminal snapshot is crossfaded by the view.
    private(set) var revisionBaseText: String?
    private(set) var revisionSuffix = ""
    private(set) var authoritativeText = ""

    mutating func replace(
    with target: String,
    at time: TimeInterval,
    settlesTail: Bool
) {
        text = target
        revisionBaseText = nil
        revisionSuffix = ""
        authoritativeText = target
        startFadeWidth = Self.minimumFadeWidth
        targetFadeWidth = Self.minimumFadeWidth
        fadeStartedAt = time
        let settledProgress = Double(target.count)
        + (settlesTail ? targetFadeWidth : 0)
        startProgress = settledProgress
        targetProgress = settledProgress
        committedProgress = Double(target.count)
        startedAt = time
    }

    /// Retargets from the exact time-interpolated position so a provider
    /// snapshot can extend the reveal without restarting or jumping it.
    /// Returns the time until this target is visually settled.
    @discardableResult
    mutating func retarget(
    to requestedTarget: String,
    at time: TimeInterval,
    settlesTail: Bool,
    minimumCharactersPerSecond: Double = 0
) -> TimeInterval {
        var target = requestedTarget
        let previousAuthoritativeText = authoritativeText
        authoritativeText = requestedTarget
        let currentProgress = progress(at: time)
        let currentFadeWidth = fadeWidth(at: time)
        let resumesFromSettledStreamingTail = settlesTail == false
        && currentProgress >= targetProgress
        && currentFadeWidth <= 1.000_001
        var sharedPrefixCount = Self.commonPrefixCount(text, target)
        var continuesExistingText = target.hasPrefix(text)
        let hadText = text.isEmpty == false

        // committedProgress is a Character count, not a fractional front.
        // Round only after a complete glyph has crossed the fade so a
        // snapshot retarget cannot make the next partial glyph pop opaque.
        let fullyVisibleProgress = max(
        0,
        floor(currentProgress - currentFadeWidth) + 1
    )
        let protectedProgress = min(
        Double(text.count),
        max(committedProgress, fullyVisibleProgress)
    )
        if settlesTail == false,
        continuesExistingText == false {
            // Never remove a glyph that has already crossed the fade. Resume
            // after the revised sentence/line boundary, and discard every
            // withdrawn glyph still waiting in the invisible reservoir.
            let visibleCharacterCount = min(
            text.count,
            max(
            Int(ceil(currentProgress)),
            Int(ceil(protectedProgress))
        )
        )
            target = monotonicRevisionTarget(
            from: requestedTarget,
            previousAuthoritative: previousAuthoritativeText,
            preserving: String(text.prefix(visibleCharacterCount))
        )
            sharedPrefixCount = Self.commonPrefixCount(text, target)
            continuesExistingText = target.hasPrefix(text)
            if target == text {
                committedProgress = protectedProgress
                let remaining = max(0, targetProgress - currentProgress)
                let frontDuration = remaining / max(charactersPerSecond, 1)
                return currentFadeWidth > 1.000_001
                ? max(frontDuration, Self.streamingTailSettleDuration)
                : frontDuration
            }
        } else if settlesTail {
            revisionBaseText = nil
            revisionSuffix = ""
        }
        committedProgress = min(
        Double(sharedPrefixCount),
        max(committedProgress, fullyVisibleProgress)
    )

        text = target
        let textEnd = Double(target.count)
        let reconciledProgress = min(
        continuesExistingText
        ? currentProgress
        : min(currentProgress, Double(sharedPrefixCount)),
        textEnd + Self.maximumFadeWidth
    )
        let usesColdFinalSweep = settlesTail
        && (
        hadText == false
        || textEnd - reconciledProgress
        > Self.maximumFinalAnimatedCharacters
    )
        let finalAnimationWindow = usesColdFinalSweep
        ? Self.maximumColdFinalAnimatedCharacters
        : Self.maximumFinalAnimatedCharacters
        // Commit the stable prefix immediately. Only a bounded trailing window
        // is animated, so a cache hit or terminal backlog never turns into a
        // multi-second full-answer typewriter effect.
        startProgress = settlesTail
        ? max(
        reconciledProgress,
        max(0, textEnd - finalAnimationWindow)
    )
        : reconciledProgress
        startedAt = time

        let baseBacklog = max(0, textEnd - startProgress)
        if settlesTail {
            if usesColdFinalSweep == false {
                targetFadeWidth = Self.finalFadeWidth
                charactersPerSecond = max(
                70,
                (baseBacklog + targetFadeWidth)
                / Self.finalSettleHorizon
            )
            } else {
                // A provider may deliver one cold snapshot or finalize with a
                // large backlog. Animate only the bounded trailing window.
                let settleHorizon = min(
                Self.coldFinalMaximumHorizon,
                max(
                Self.coldFinalMinimumHorizon,
                baseBacklog
                / Self.coldFinalPreferredCharactersPerSecond
            )
            )
                let preliminarySpeed = max(
                70,
                baseBacklog / settleHorizon
            )
                targetFadeWidth = min(
                Self.maximumFadeWidth,
                max(Self.finalFadeWidth, preliminarySpeed * 0.10)
            )
                charactersPerSecond = max(
                70,
                (baseBacklog + targetFadeWidth) / settleHorizon
            )
            }
        } else {
            let desiredSpeed = min(
            180,
            max(48, baseBacklog / 0.24)
        )
            if hadText {
                charactersPerSecond += (desiredSpeed - charactersPerSecond) * 0.22
            } else {
                charactersPerSecond = desiredSpeed
            }
            charactersPerSecond = max(
            charactersPerSecond,
            minimumCharactersPerSecond
        )
            targetFadeWidth = min(
            Self.maximumFadeWidth,
            max(Self.minimumFadeWidth, charactersPerSecond * 0.10)
        )
        }
        startFadeWidth = resumesFromSettledStreamingTail
        ? max(currentFadeWidth, targetFadeWidth)
        : currentFadeWidth

        // A final response can arrive as one large snapshot. Keep its reveal at
        // the real front so no large answer appears abruptly; only glyphs that
        // have actually crossed the moving tail become the committed text run.
        if settlesTail {
            let widestFade = max(startFadeWidth, targetFadeWidth)
            let fullyVisibleAtStart = max(
            0,
            floor(startProgress - widestFade) + 1
        )
            committedProgress = min(
            textEnd,
            max(committedProgress, fullyVisibleAtStart)
        )
        }
        fadeStartedAt = time
        if settlesTail {
            targetProgress = textEnd + targetFadeWidth
        } else {
            let annotatedWindowEnd = Double(
            Int(floor(committedProgress))
            + AssistantContinuousRevealMetrics
            .maximumAnnotatedCharacterCount
        )
            targetProgress = min(
            textEnd,
            max(startProgress, annotatedWindowEnd)
        )
        }
        startProgress = min(startProgress, targetProgress)
        let backlog = max(0, targetProgress - startProgress)
        let revealDuration = backlog > 0
        ? backlog / charactersPerSecond
        : 0
        // Reaching the provider's latest character is not the
        // visual reveal. The soft glyph tail still needs to collapse to full
        // opacity. Keeping the display clock alive for that interval avoids a
        // pause followed by an opaque "pop" on the next provider snapshot.
        if settlesTail == false,
        max(currentFadeWidth, targetFadeWidth) > 0 {
            return revealDuration + Self.streamingTailSettleDuration
        }
        return revealDuration
    }
    func progress(at time: TimeInterval) -> Double {
        guard targetProgress > startProgress else { return targetProgress }
        let elapsed = max(0, time - startedAt)
        return min(
        targetProgress,
        startProgress + elapsed * charactersPerSecond
    )
    }
    func fadeWidth(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - fadeStartedAt)
        let interpolatedWidth = interpolatedFadeWidth(after: elapsed)
        // While generation is open, never advance beyond the current target;
        // While generation is open, never advance beyond the current target:
        // doing so would reveal future appended glyphs instantly. Instead,
        // collapse the active fade after the front catches up, leaving the
        // current tail fully opaque without banking logical progress.
        guard targetProgress <= Double(text.count) else {
            return interpolatedWidth
        }
        let revealDuration = max(
        0,
        (targetProgress - startProgress) / max(1, charactersPerSecond)
    )
        let settleElapsed = max(0, time - startedAt - revealDuration)
        let widthAtFrontArrival = interpolatedFadeWidth(
        after: revealDuration
    )
        let settleFraction = min(
        1,
        settleElapsed / Self.streamingTailSettleDuration
    )
        let easedSettle = settleFraction
        * settleFraction
        * (3 - 2 * settleFraction)
        return widthAtFrontArrival
        + (1 - widthAtFrontArrival) * easedSettle
    }

    func hasCommittedDivergence(
    from target: String,
    at time: TimeInterval
) -> Bool {
        guard target.hasPrefix(text) == false else { return false }
        let fullyVisible = max(
        0,
        floor(progress(at: time) - fadeWidth(at: time)) + 1
    )
        let protected = min(
        Double(text.count),
        max(committedProgress, fullyVisible)
    )
        return Double(Self.commonPrefixCount(text, target)) < protected
    }

    // Captures only the glyph horizon that has actually reached the display.
    // A divergent terminal rewrite can use this as a temporary bridge without
    // exposing the model's still-hidden reservoir in one frame.
    func visibleText(at time: TimeInterval) -> String {
        let visibleCharacterCount = min(
        text.count,
        max(0, Int(ceil(progress(at: time))))
    )
        return String(text.prefix(visibleCharacterCount))
    }

    func terminalHandoff(
    to target: String,
    at time: TimeInterval
) -> AssistantTerminalRevealHandoff? {
        guard target.isEmpty == false,
        hasCommittedDivergence(from: target, at: time) else {
            return nil
        }
        let bridgeText = visibleText(at: time)
        let authoritativePrefixCount = min(
        target.count,
        max(
        1,
        min(
        bridgeText.count,
        AssistantContinuousRevealMetrics
        .maximumTerminalHandoffCharacterCount
    )
    )
    )
        return AssistantTerminalRevealHandoff(
        bridgeText: bridgeText,
        authoritativePrefix: String(
        target.prefix(authoritativePrefixCount)
    )
    )
    }

    func unrevealedTerminalCharacterCount(
    to target: String,
    at time: TimeInterval
) -> Double {
        let fullyVisibleProgress = max(
        0,
        floor(progress(at: time) - fadeWidth(at: time)) + 1
    )
        let sharedPrefixCount = Self.commonPrefixCount(text, target)
        let reconciledCommittedProgress = min(
        Double(sharedPrefixCount),
        max(committedProgress, fullyVisibleProgress)
    )
        return max(
        0,
        Double(target.count) - reconciledCommittedProgress
    )
    }

    private func interpolatedFadeWidth(after elapsed: TimeInterval) -> Double {
        let fraction = min(
        1,
        elapsed / Self.fadeWidthTransitionDuration
    )
        let easedFraction = fraction * fraction * (3 - 2 * fraction)
        return startFadeWidth
        + (targetFadeWidth - startFadeWidth) * easedFraction
    }

    private static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex
        var count = 0
        while lhsIndex < lhs.endIndex,
        rhsIndex < rhs.endIndex,
        lhs[lhsIndex] == rhs[rhsIndex] {
            count += 1
            lhs.formIndex(after: &lhsIndex)
            rhs.formIndex(after: &rhsIndex)
        }
        return count
    }

    private mutating func monotonicRevisionTarget(
    from authoritative: String,
    previousAuthoritative: String,
    preserving base: String
) -> String {
        guard previousAuthoritative.isEmpty == false else { return base }
        guard let suffix = Self.newlyAppendedSemanticSuffix(
        previous: previousAuthoritative,
        current: authoritative
    ),
        suffix.isEmpty == false else { return base }

        var existingKeys = Set(
        Self.semanticUnits(in: text).map(Self.semanticUnitKey)
    )
        let uniqueSuffixUnits = Self.semanticUnits(in: suffix).filter { unit in
            existingKeys.insert(Self.semanticUnitKey(unit)).inserted
        }
        guard uniqueSuffixUnits.isEmpty == false else { return base }
        let uniqueSuffix = uniqueSuffixUnits.joined(separator: " ")

        // Preserve only the portion of the old reservoir that has reached the
        // reveal front. Hidden revoked claims must stop immediately. Append only
        // complete, genuinely new semantic units, de-duplicated against every
        // unit already retained across earlier revisions/oscillations.
        revisionBaseText = base
        let previousRevisionSuffix = revisionSuffix
        revisionSuffix = uniqueSuffix
        let resumesPriorSuffix = previousRevisionSuffix.isEmpty == false
        && Self.semanticUnitKey(previousRevisionSuffix)
        == Self.semanticUnitKey(uniqueSuffix)
        let overlap = resumesPriorSuffix
        ? Self.suffixPrefixOverlapCount(base, uniqueSuffix)
        : 0
        if overlap > 0 {
            let suffixStart = uniqueSuffix.index(
            uniqueSuffix.startIndex,
            offsetBy: overlap
        )
            return base + String(uniqueSuffix[suffixStart...])
        }
        let separator = base.isEmpty || base.last?.isWhitespace == true ? "" : " "
        return base + separator + revisionSuffix
    }

    private static func suffixPrefixOverlapCount(
    _ base: String,
    _ suffix: String
) -> Int {
        let maximum = min(base.count, suffix.count)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            if String(base.suffix(length)).compare(
            String(suffix.prefix(length)),
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame {
                return length
            }
        }
        return 0
    }

    private static func newlyAppendedSemanticSuffix(
    previous: String,
    current: String
) -> String? {
        let previousUnits = settledSemanticUnits(in: previous)
        let currentUnits = settledSemanticUnits(in: current)
        guard previousUnits.isEmpty == false,
        currentUnits.isEmpty == false else { return nil }

        let previousTokens = semanticContentTokens(
        in: previousUnits.joined(separator: " ")
    )
        var bestPrefixLength = min(previousUnits.count, currentUnits.count)
        var bestScore = -1.0
        var candidatePrefix = ""
        var bestPrefix = ""
        for length in 1...currentUnits.count {
            if candidatePrefix.isEmpty == false { candidatePrefix += " " }
            candidatePrefix += currentUnits[length - 1]
            let prefixTokens = semanticContentTokens(in: candidatePrefix)
            let score = tokenDiceSimilarity(previousTokens, prefixTokens)
            if score > bestScore + 0.000_001 {
                bestScore = score
                bestPrefixLength = length
                bestPrefix = candidatePrefix
            }
        }

        guard bestPrefixLength < currentUnits.count else { return nil }
        if prefix(bestPrefix, coversEveryUnitIn: previousUnits) {
            return currentUnits[bestPrefixLength...].joined(separator: " ")
        }

        // A provider may revise one unit and append another in the same
        // snapshot. Keep the first N current units inside the prior horizon,
        // but reject a shifted insertion: when a later horizon unit maps back
        // to an already-covered earlier prior unit, positional tail inference
        // would mispublish the replacement as an append.
        guard currentUnits.count > previousUnits.count else { return nil }
        let previousHorizon = Array(currentUnits.prefix(previousUnits.count))
        let hasStableAnchor = previousHorizon.contains { currentUnit in
            previousUnits.contains { previousUnit in
                tokenDiceSimilarity(
                semanticContentTokens(in: currentUnit),
                semanticContentTokens(in: previousUnit)
            ) >= 0.60
            }
        }
        guard hasStableAnchor else { return nil }
        let hasShiftedEarlierAnchor = previousHorizon.enumerated().contains {
            currentIndex, currentUnit in
            let currentTokens = semanticContentTokens(in: currentUnit)
            let best = previousUnits.enumerated().map { previousIndex, previousUnit in
                (
                previousIndex,
                tokenDiceSimilarity(
                currentTokens,
                semanticContentTokens(in: previousUnit)
            )
            )
            }
                .max(by: { $0.1 < $1.1 })
            return best.map {
                $0.1 > 0
                && $0.0 < currentIndex
            } ?? false
        }
        guard hasShiftedEarlierAnchor == false else { return nil }
        let candidateSuffix = currentUnits.dropFirst(previousUnits.count)
        let repeatsPreviousUnit = candidateSuffix.contains { candidate in
            previousUnits.contains { previousUnit in
                tokenDiceSimilarity(
                semanticContentTokens(in: candidate),
                semanticContentTokens(in: previousUnit)
            ) >= 0.60
            }
        }
        guard repeatsPreviousUnit == false else { return nil }
        return candidateSuffix.joined(separator: " ")
    }

    private static func semanticUnits(in text: String) -> [String] {
        let characters = Array(text)
        let ends = semanticUnitEndOffsets(in: text)
        var start = 0
        var units: [String] = []
        for end in ends {
            while start < end, characters[start].isWhitespace { start += 1 }
            let unit = String(characters[start..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if unit.isEmpty == false { units.append(unit) }
            start = end
        }
        return units
    }
    private static func settledSemanticUnits(in text: String) -> [String] {
        var units = semanticUnits(in: text)
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return [] }
        if last.isNewline { return units }
        let terminalClosers: Set<Character> = [
        "\"", "'", "”", "’", ")", "]", "}", "»",
    ]
        while let closing = trimmed.last, terminalClosers.contains(closing) {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        if let semanticLast = trimmed.last,
        ".!?".contains(semanticLast) == false {
            units.removeLast()
        }
        return units
    }

    private static func semanticUnitKey(_ unit: String) -> String {
        unit.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
        .unicodeScalars
        .split { CharacterSet.alphanumerics.contains($0) == false }
        .map(String.init)
        .joined(separator: " ")
    }

    private static func semanticTokens(in text: String) -> [String: Int] {
        let folded = text.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
        let tokens = folded.unicodeScalars
        .split { CharacterSet.alphanumerics.contains($0) == false }
        .map(String.init)
        return tokens.reduce(into: [:]) { counts, token in
            counts[token, default: 0] += 1
        }
    }

    private static let semanticStopwords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "for", "from",
    "in", "is", "it", "of", "on", "or", "the", "to", "was", "were",
]

    /// Semantic-unit reconciliation uses content words to locate the boundary
    /// between a revised prefix and genuinely appended facts. Function words
    /// such as "is" must not make a later sentence look more like the old
    /// prefix merely because the provider merged or split sentence units.
    private static func semanticContentTokens(in text: String) -> [String: Int] {
        semanticTokens(in: text).reduce(into: [:]) { result, pair in
            guard semanticStopwords.contains(pair.key) == false else { return }
            result[pair.key] = pair.value
        }
    }

    private static func tokenDiceSimilarity(
    _ lhs: [String: Int],
    _ rhs: [String: Int]
) -> Double {
        let lhsCount = lhs.values.reduce(0, +)
        let rhsCount = rhs.values.reduce(0, +)
        guard lhsCount + rhsCount > 0 else { return 0 }
        let overlap = tokenOverlapCount(lhs, rhs)
        return 2 * Double(overlap) / Double(lhsCount + rhsCount)
    }

    private static func tokenOverlapCount(
    _ lhs: [String: Int],
    _ rhs: [String: Int]
) -> Int {
        lhs.reduce(into: 0) { total, pair in
            total += min(pair.value, rhs[pair.key, default: 0])
        }
    }

    private static func prefix(
    _ prefix: String,
    coversEveryUnitIn previousUnits: [String]
) -> Bool {
        let prefixTokens = Set(semanticContentTokens(in: prefix).keys)
        guard prefixTokens.isEmpty == false else { return false }
        return previousUnits.allSatisfy { unit in
            semanticContentTokens(in: unit).keys.contains { token in
                prefixTokens.contains(token)
            }
        }
    }

    private static func semanticUnitEndOffsets(in text: String) -> [Int] {
        let characters = Array(text)
        var ends: [Int] = []
        var unitStart = 0

        func appendUnit(endingAt end: Int) {
            guard end > unitStart,
            characters[unitStart..<end].contains(where: {
                $0.isWhitespace == false
            }) else {
                unitStart = max(unitStart, end)
                return
            }
            ends.append(end)
            unitStart = end
        }

        for index in characters.indices {
            if characters[index].isNewline {
                appendUnit(endingAt: index)
                unitStart = index + 1
            } else if ".!?".contains(characters[index]) {
                let terminalClosers: Set<Character> = [
                "\"", "'", "”", "’", ")", "]", "}", "»",
            ]
                var boundary = index + 1
                while boundary < characters.count,
                terminalClosers.contains(characters[boundary]) {
                    boundary += 1
                }
                if boundary == characters.count
                || characters[boundary].isWhitespace {
                    appendUnit(endingAt: boundary)
                    unitStart = boundary
                }
            }
        }
        appendUnit(endingAt: characters.count)
        return ends
    }
}

private struct AssistantStreamRevealTarget: Hashable {
    let text: String
    let isStreaming: Bool
    let isFinal: Bool
    let usesStaticReveal: Bool
}

private struct AssistantResponseRevealText: View {
    let text: String
    let isStreaming: Bool
    let isFinal: Bool
    let animatesEntrance: Bool
    let onEntranceCompleted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var continuousReveal = AssistantContinuousStreamReveal()
    @State private var revealProgress: CGFloat = 0
    @State private var showsFormattedResponse = false
    @State private var formattedResponseText = ""
    @State private var pendingRevealTarget: AssistantStreamRevealTarget?
    @State private var entranceDidSettle = false
    @State private var contentDidSettle = false
    @State private var didReportEntranceCompletion = false
    @State private var streamClockIsPaused = true

    private var usesStaticReveal: Bool {
        animatesEntrance == false
        || AssistantRevealMotionPolicy.usesStaticPresentation(
        reduceMotion: reduceMotion,
        voiceOverEnabled: voiceOverEnabled,
        isUITesting: NotateUITestLaunchConfiguration.isEnabled
    )
    }

    private var effectiveRevealProgress: CGFloat {
        usesStaticReveal ? 1 : revealProgress
    }

    private var revealTarget: AssistantStreamRevealTarget {
        AssistantStreamRevealTarget(
        text: text,
        isStreaming: isStreaming,
        isFinal: isFinal,
        usesStaticReveal: usesStaticReveal
    )
    }

    var body: some View {
        responseContent
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)

        .opacity(0.18 + Double(effectiveRevealProgress) * 0.82)
        .offset(y: 7 * (1 - effectiveRevealProgress))
        .accessibilityLabel(
        Text(verbatim: text)
    )
        .accessibilityAddTraits(
        isStreaming ? .updatesFrequently : []
    )
        // Cumulative model snapshots are unstable. VoiceOver already gets
        // the scoped progress announcement above; expose the response only
        // when its authoritative terminal value is ready.
        .accessibilityHidden(voiceOverEnabled && isFinal == false)
        .task {
            await animateEntranceIfNeeded()
        }
            .task(id: revealTarget) {
            await presentRevealTarget(revealTarget)
        }
    }

    @ViewBuilder
    private var responseContent: some View {
        ZStack(alignment: .topLeading) {
            AssistantStreamingText(
            reveal: continuousReveal,
            isPaused: showsFormattedResponse || streamClockIsPaused
        )
            .opacity(showsFormattedResponse ? 0 : 1)
            .accessibilityHidden(showsFormattedResponse)

            VStack(alignment: .leading, spacing: NotateDesign.Spacing.compact) {
                Text(verbatim: formattedResponseText)
                .font(.callout)
                .lineSpacing(3)
            }
                .opacity(showsFormattedResponse ? 1 : 0)
                .accessibilityHidden(showsFormattedResponse == false)
                .allowsHitTesting(showsFormattedResponse)
        }
    }

    @MainActor
    private func animateEntranceIfNeeded() async {
        guard usesStaticReveal == false else {
            revealProgress = 1
            entranceDidSettle = true
            reportCompletionIfSettled()
            return
        }
        revealProgress = 0
        await Task.yield()
        guard Task.isCancelled == false else { return }
        await withCheckedContinuation { continuation in
            withAnimation(
            .smooth(duration: AssistantResponseRevealPolicy.entranceDuration),
            completionCriteria: .logicallyComplete
        ) {
                revealProgress = 1
            } completion: {
                continuation.resume()
            }
        }
        guard Task.isCancelled == false else { return }
        entranceDidSettle = true
        reportCompletionIfSettled()
    }
    /// Retargets one continuous glyph front. Model snapshots update the hidden
    /// layout reservoir; display refreshes reveal it without substring edits.
    @MainActor
    private func presentRevealTarget(
    _ nextTarget: AssistantStreamRevealTarget
) async {
        let projectedText = nextTarget.text
        pendingRevealTarget = nextTarget
        let now = ProcessInfo.processInfo.systemUptime
        if nextTarget.usesStaticReveal {
            var reveal = continuousReveal
            reveal.replace(
            with: projectedText,
            at: now,
            settlesTail: true
        )
            continuousReveal = reveal
            streamClockIsPaused = true
            formattedResponseText = nextTarget.text
            showsFormattedResponse = nextTarget.isStreaming == false
            if nextTarget.isFinal {
                await Task.yield()
                guard Task.isCancelled == false else { return }
                contentDidSettle = true
                reportCompletionIfSettled()
            }
            return
        }

        if nextTarget.isFinal == false {
            contentDidSettle = false
        }

        let terminalHandoff = nextTarget.isStreaming
        ? continuousReveal.terminalHandoff(
        to: projectedText,
        at: now
    )
        : nil
        if let terminalHandoff {
            // Preserve only the old glyph horizon that was genuinely visible.
            // Build a fresh, bounded authoritative prefix while that bridge is
            // still covering the render. The crossfade therefore never
            // lands on an empty/fresh front, and the remaining authoritative
            // suffix can continue forward from this stable prefix.
            streamClockIsPaused = true
            formattedResponseText = terminalHandoff.bridgeText
            await Task.yield()
            guard Task.isCancelled == false,
            pendingRevealTarget == nextTarget else { return }
            showsFormattedResponse = true

            var handoffReveal = AssistantContinuousStreamReveal()
            let handoffStartAt = ProcessInfo.processInfo.systemUptime
            let handoffDuration = handoffReveal.retarget(
            to: terminalHandoff.authoritativePrefix,
            at: handoffStartAt,
            settlesTail: false,
            minimumCharactersPerSecond: 180
        )
            continuousReveal = handoffReveal
            streamClockIsPaused = handoffDuration <= 0
            if handoffDuration > 0 {
                do {
                    try await Task.sleep(for: .seconds(handoffDuration))
                } catch {
                    return
                }
            } else {
                await Task.yield()
            }
            guard Task.isCancelled == false,
            pendingRevealTarget == nextTarget else { return }
            streamClockIsPaused = true
            await Task.yield()
            guard Task.isCancelled == false,
            pendingRevealTarget == nextTarget else { return }

            await withCheckedContinuation { continuation in
                withAnimation(
                .smooth(duration: 0.20),
                completionCriteria: .logicallyComplete
            ) {
                    showsFormattedResponse = false
                } completion: {
                    continuation.resume()
                }
            }
            guard Task.isCancelled == false,
            pendingRevealTarget == nextTarget else { return }
        }

        if terminalHandoff == nil,
        showsFormattedResponse || continuousReveal.text != projectedText {
            withAnimation(.easeOut(duration: 0.12)) {
                showsFormattedResponse = false
            }
        }

        let retargetedAt = ProcessInfo.processInfo.systemUptime
        var reveal = continuousReveal
        var settleDuration = reveal.retarget(
        to: projectedText,
        at: retargetedAt,
        settlesTail: nextTarget.isStreaming == false
    )
        continuousReveal = reveal

        while true {
            streamClockIsPaused = settleDuration <= 0
            if settleDuration > 0 {
                do {
                    try await Task.sleep(for: .seconds(settleDuration))
                } catch {
                    return
                }
            } else {
                await Task.yield()
            }
            guard Task.isCancelled == false,
            pendingRevealTarget == nextTarget else { return }
            let hasPendingStreamingPage = nextTarget.isStreaming
            && Double(continuousReveal.targetProgress.count) < Double(projectedText.count)
            guard hasPendingStreamingPage else { break }

            var nextPage = continuousReveal
            settleDuration = nextPage.retarget(
            to: projectedText,
            at: ProcessInfo.processInfo.systemUptime,
            settlesTail: false
        )
            continuousReveal = nextPage
        }

        streamClockIsPaused = true
        guard nextTarget.isStreaming == false else { return }
        if showsFormattedResponse == false {
            formattedResponseText = nextTarget.text
            // Commit the final formatted geometry while it is still
            // transparent, then crossfade without replacing the layout tree.
            await Task.yield()
            guard Task.isCancelled == false,
            pendingRevealTarget == nextTarget else { return }
            await withCheckedContinuation { continuation in
                withAnimation(
                .smooth(duration: 0.16),
                completionCriteria: .logicallyComplete
            ) {
                    showsFormattedResponse = true
                } completion: {
                    continuation.resume()
                }
            }
        }
        guard Task.isCancelled == false,
        pendingRevealTarget == nextTarget,
        nextTarget.isFinal else { return }
        contentDidSettle = true
        reportCompletionIfSettled()
    }

    @MainActor
    private func reportCompletionIfSettled() {
        guard entranceDidSettle,
        contentDidSettle,
        didReportEntranceCompletion == false else { return }
        didReportEntranceCompletion = true
        onEntranceCompleted()
    }
}

/// SwiftUI layout indices are deliberately opaque, so the moving tail carries
/// an explicit source-Character position instead. Applying one attribute per
/// grapheme keeps every glyph in an emoji or complex-script cluster together.
private struct AssistantSourceCharacterPosition: TextAttribute, Sendable {
    let value: Double
}

private struct AssistantPendingStreamSuffix: TextAttribute, Sendable {}

enum AssistantBalancedComposition {
    /// Combines a sequence as a balanced tree instead of a left-deep chain.
    /// SwiftUI recursively resolves interpolated `Text` storage, so folding
    /// hundreds of attributed glyphs one at a time can exhaust the main-thread
    /// stack while a model response is streaming.
    static func combine<Element>(
    _ elements: [Element],
    using combinePair: (Element, Element) -> Element
) -> Element? {
        guard elements.isEmpty == false else { return nil }

        var level = elements
        while level.count > 1 {
            var nextLevel: [Element] = []
            nextLevel.reserveCapacity((level.count + 1) / 2)

            var index = 0
            while index + 1 < level.count {
                nextLevel.append(
                combinePair(level[index], level[index + 1])
            )
                index += 2
            }
            if index < level.count {
                nextLevel.append(level[index])
            }
            level = nextLevel
        }
        return level[0]
    }
}

private enum AssistantStreamingTextContent {
    static func make(
    _ source: String,
    committedProgress: Double
) -> Text {
        let committedCharacterCount = min(
        source.count,
        max(0, Int(floor(committedProgress)))
    )
        let tailStart = source.index(
        source.startIndex,
        offsetBy: committedCharacterCount
    )
        let annotatedCharacterCount = min(
        source.distance(from: tailStart, to: source.endIndex),
        AssistantContinuousRevealMetrics.maximumAnnotatedCharacterCount
    )
        let annotatedTailEnd = source.index(
        tailStart,
        offsetBy: annotatedCharacterCount
    )
        var fragments = [Text]()
        fragments.reserveCapacity(annotatedCharacterCount + 2)
        fragments.append(Text(verbatim: String(source[..<tailStart])))
        var sourcePosition = committedCharacterCount
        for character in source[tailStart..<annotatedTailEnd] {
            let fragment = Text(verbatim: String(character))
            .customAttribute(
            AssistantSourceCharacterPosition(
            value: Double(sourcePosition)
        )
        )
            fragments.append(fragment)
            sourcePosition += 1
        }
        if annotatedTailEnd < source.endIndex {
            let pendingSuffix = Text(
            verbatim: String(source[annotatedTailEnd...])
        )
            .customAttribute(AssistantPendingStreamSuffix())
            fragments.append(pendingSuffix)
        }
        return AssistantBalancedComposition.combine(fragments) { leading, trailing in
            Text("\(leading)\(trailing)")
        } ?? Text(verbatim: "")
    }
}

/// Draws the committed prefix normally and applies a run-level effect only to
/// the short grapheme-tagged tail. The front is measured in source Characters,
/// so appending complex-script text cannot move or dim an already-visible
/// prefix.
private struct AssistantContinuousTextRenderer: TextRenderer {
    var front: Double
    var committedFront: Double
    var fadeWidth: Double

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get {
            AnimatablePair(
            AnimatablePair(front, committedFront),
            fadeWidth
        )
        }
        set {
            front = newValue.first.first
            committedFront = newValue.first.second
            fadeWidth = newValue.second
        }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let effectiveFadeWidth = max(1, fadeWidth)
        let fullyVisibleFront = front - effectiveFadeWidth

        for line in layout {
            for run in line {
                if run[AssistantPendingStreamSuffix.self] != nil {
                    continue
                }
                guard let sourcePosition = run[
                AssistantSourceCharacterPosition.self
            ]?.value else {
                    // The committed prefix is intentionally unannotated so it
                    // remains one normally rendered, inexpensive text run.
                    context.draw(run)
                    continue
                }
                if sourcePosition < committedFront
                || sourcePosition <= fullyVisibleFront {
                    context.draw(run)
                    continue
                }

                let rawProgress = min(
                1,
                max(
                0,
                (front - sourcePosition) / effectiveFadeWidth
            )
            )
                let easedProgress = rawProgress
                * rawProgress
                * (3 - 2 * rawProgress)
                guard easedProgress > 0 else { continue }
                var glyphContext = context
                glyphContext.opacity = easedProgress
                glyphContext.translateBy(
                x: 0,
                y: (1 - easedProgress) * 1.25
            )
                glyphContext.draw(run)
            }
        }
    }
}

/// The target String changes only at the coalesced model cadence. Between
/// snapshots, TimelineView advances a fractional glyph front at the display's
/// own cadence and pauses only after the current soft tail is fully settled.
private struct AssistantStreamingText: View {
    let reveal: AssistantContinuousStreamReveal
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usesStaticPresentation: Bool {
        reduceMotion || NotateUITestLaunchConfiguration.isEnabled
    }

    @ViewBuilder
    var body: some View {
        if usesStaticPresentation {
            Text(verbatim: reveal.text)
            .font(.callout)
            .lineSpacing(3)
        } else {
            let positionedText = AssistantStreamingTextContent.make(
            reveal.text,
            committedProgress: reveal.committedProgress
        )
            TimelineView(.animation(paused: isPaused)) { _ in
                let now = ProcessInfo.processInfo.systemUptime
                positionedText
                .font(.callout)
                .lineSpacing(3)
                .textRenderer(
                AssistantContinuousTextRenderer(
                front: reveal.progress(at: now),
                committedFront: reveal.committedProgress,
                fadeWidth: reveal.fadeWidth(at: now)
            )
            )
            }
        }
    }
}

private enum AssistantThinkingMarkPhase: CaseIterable {
    case resting
    case considering
    case resolving

    var scale: CGFloat {
        switch self {
            case .resting: 0.94
            case .considering: 1.04
            case .resolving: 0.98
        }
    }

    var verticalOffset: CGFloat {
        switch self {
            case .resting: 0.7
            case .considering: -0.8
            case .resolving: 0
        }
    }

    var rotation: Angle {
        switch self {
            case .resting: .degrees(-2.5)
            case .considering: .degrees(2)
            case .resolving: .zero
        }
    }

    var shimmerOffset: CGFloat {
        switch self {
            case .resting: -17
            case .considering: 0
            case .resolving: 17
        }
    }

    var shimmerOpacity: Double {
        switch self {
            case .resting, .resolving: 0
            case .considering: 1
        }
    }

    var spectrumPhase: Double {
        switch self {
            case .resting: 0.08
            case .considering: 0.42
            case .resolving: 0.76
        }
    }
}

/// Animates Notate's own mark instead of introducing a generic loading glyph.
/// The motion is deliberately small so it reads as thought, not decoration.
private struct AssistantThinkingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var usesStaticPresentation: Bool {
        reduceMotion || NotateUITestLaunchConfiguration.isEnabled
    }

    @ViewBuilder
    var body: some View {
        if usesStaticPresentation {
            mark(phase: .resolving)
        } else {
            PhaseAnimator(AssistantThinkingMarkPhase.allCases) { phase in
                mark(phase: phase)
            } animation: { phase in
                switch phase {
                    case .resting: .smooth(duration: 0.52)
                    case .considering: .smooth(duration: 0.68)
                    case .resolving: .smooth(duration: 0.56)
                }
            }
        }
    }

    private func mark(phase: AssistantThinkingMarkPhase) -> some View {
        ZStack {
            NotateAgentMark(
            tint: Color.primary.opacity(colorScheme == .dark ? 0.72 : 0.62),
            size: 18
        )

            MeshGradient(
            width: 3,
            height: 3,
            points: AssistantSpectrumVisual.meshPoints(phase: phase.spectrumPhase),
            colors: AssistantSpectrumVisual.meshColors
        )
            .saturation(colorScheme == .dark ? 1.08 : 0.98)
            .frame(width: 24, height: 24)
            .mask {
                NotateAgentMark(tint: .white, size: 18)
            }

            if reduceTransparency == false {
                LinearGradient(
                colors: [
                .clear,
                Color.white.opacity(colorScheme == .dark ? 0.92 : 0.78),
                .clear,
            ],
                startPoint: .leading,
                endPoint: .trailing
            )
                .frame(width: 9, height: 22)
                .offset(x: phase.shimmerOffset)
                .opacity(phase.shimmerOpacity)
                .mask {
                    NotateAgentMark(tint: .white, size: 18)
                }
            }
        }
                    .scaleEffect(phase.scale)
                    .rotationEffect(phase.rotation)
                    .offset(y: phase.verticalOffset)
                    .shadow(
        color: reduceTransparency
        ? .clear
        : NotateDesign.Palette.assistantViolet.opacity(
        colorScheme == .dark ? 0.24 : 0.13
    ),
        radius: 2.4,
        y: 1
    )
        .frame(width: 24, height: 20)
    }
}

/// Keeps the prompt field neutral while letting a thin spectral edge signal
/// that the submitted request is still active, including during streaming.
private struct AssistantSpectrumRim: View {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var usesStaticPresentation: Bool {
        reduceMotion || NotateUITestLaunchConfiguration.isEnabled
    }

    @ViewBuilder
    var body: some View {
        if usesStaticPresentation {
            rim(phase: 0.18, energy: 0.55)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: 5.6) / 5.6
                let energy = (sin(elapsed * 2.2) + 1) / 2

                rim(phase: phase, energy: energy)
            }
        }
    }

    private func rim(phase: Double, energy: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let spectrum = MeshGradient(
        width: 3,
        height: 3,
        points: AssistantSpectrumVisual.meshPoints(phase: phase),
        colors: AssistantSpectrumVisual.meshColors
    )

        return ZStack {
            if reduceTransparency == false {
                spectrum
                    .mask(shape.strokeBorder(lineWidth: 5))
                    .blur(radius: 3.6)
                    .opacity(
                    (colorScheme == .dark ? 0.26 : 0.14)
                    + energy * 0.08
                )
            }

            spectrum
                .saturation(colorScheme == .dark ? 1.08 : 0.98)
                .mask(
                    shape.strokeBorder(
                    lineWidth: contrast == .increased ? 2.2 : 1.35
                )
            )
            .opacity(reduceTransparency ? 1 : 0.76 + energy * 0.16)
        }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private enum AssistantSpectrumVisual {
    static func meshPoints(phase: Double) -> [SIMD2<Float>] {
        let turn = phase * .pi * 2
        let horizontal = Float(sin(turn))
        let vertical = Float(cos(turn * 2))
        let counter = Float(sin(turn * 3 + 1.4))

        return [
        SIMD2(0, 0),
        SIMD2(0.50 + horizontal * 0.10, 0),
        SIMD2(1, 0),
        SIMD2(0, 0.50 + counter * 0.09),
        SIMD2(0.50 + counter * 0.12, 0.50 + vertical * 0.12),
        SIMD2(1, 0.50 - horizontal * 0.09),
        SIMD2(0, 1),
        SIMD2(0.50 - vertical * 0.10, 1),
        SIMD2(1, 1)
    ]
    }

    static var meshColors: [Color] {
        let palette = NotateDesign.Palette.self
        return [
        palette.assistantCyan,
        palette.assistantBlue,
        palette.assistantViolet,
        palette.assistantBlue,
        palette.assistantPink,
        palette.assistantCoral,
        palette.assistantViolet,
        palette.assistantAmber,
        palette.assistantPink
    ]
    }
}

private extension AssistantSourceAnchor {
    var locationTitle: String {
        if let pageNumber { return "\(itemName) · Page \(pageNumber)" }
        return itemName
    }
}

private extension AssistantSourceKind {
    var accessibilityTitle: String {
        switch self {
            case .paperKitText: "Note text"
            case .pdfText: "PDF text"
            case .imageContent: "Image content"
            case .metadata: "Note details"
        }
    }

    var systemImage: String {
        switch self {
            case .paperKitText: "pencil.and.scribble"
            case .pdfText: "doc.richtext"
            case .imageContent: "photo.on.rectangle.angled"
            case .metadata: "tag"
        }
    }
}
