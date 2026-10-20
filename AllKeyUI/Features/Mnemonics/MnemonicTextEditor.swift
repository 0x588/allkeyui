import AppKit
import SwiftUI

/// Token ranges use UTF-16, matching NSTextView, and preserve the original whitespace.
struct MnemonicCompletionTarget: Equatable {
    let position: Int
    let range: NSRange
    let word: String

    static func tokens(in text: String) -> [Self] {
        guard let pattern = try? NSRegularExpression(pattern: #"\S+"#) else { return [] }
        let source = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).enumerated().map {
            Self(position: $0.offset, range: $0.element.range, word: source.substring(with: $0.element.range))
        }
    }

    static func atSelection(_ selection: NSRange, in text: String) -> Self? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= (text as NSString).length,
              selection.length <= (text as NSString).length - selection.location else { return nil }
        return tokens(in: text).first {
            $0.range.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0.range)
                && $0.word != "?"
        }
    }
}

struct MnemonicInputSelection: Equatable {
    let id = UUID()
    let range: NSRange
}

struct MnemonicCompletionEdit {
    let range: NSRange
    let replacement: String
    let text: String
    let selection: NSRange

    static func make(text: String, position: Int, word: String) -> Self? {
        let tokens = MnemonicCompletionTarget.tokens(in: text)
        guard tokens.indices.contains(position), tokens[position].word != "?" else { return nil }
        let range = tokens[position].range
        let source = text as NSString
        let replacement = word + (NSMaxRange(range) == source.length ? " " : "")
        let updated = source.replacingCharacters(in: range, with: replacement)
        var caret = range.location + (replacement as NSString).length
        if NSMaxRange(range) < source.length,
           let suffix = Range(NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range)), in: text),
           let delimiter = text[suffix].first, delimiter.isWhitespace {
            caret += (String(delimiter) as NSString).length
        }
        return Self(range: range, replacement: replacement, text: updated, selection: NSRange(location: caret, length: 0))
    }
}

struct MnemonicTextEditor: NSViewRepresentable {
    @Binding var text: String
    let inspection: MnemonicInputInspection?
    let inspectionText: String?
    let selectionRequest: MnemonicInputSelection?
    let onChange: (String, NSRange) -> Void
    let onSelection: (NSRange) -> Void
    let onSearch: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = MnemonicNativeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 92))
        editor.delegate = context.coordinator
        editor.coordinator = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("助记词，使用问号代替缺失的单词")
        editor.setAccessibilityHelp("输入字母显示本地词表候选。上下方向键选择，回车或 Tab 补全，Esc 关闭。")
        scroll.documentView = editor
        context.coordinator.editor = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.applyParentState(isEnabled: context.environment.isEnabled)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
        coordinator.editor?.delegate = nil
        coordinator.editor?.coordinator = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MnemonicTextEditor
        weak var editor: MnemonicNativeTextView?
        private var isUpdating = false
        private var isActive = true
        private var updateQueued = false
        private var pendingInput: PendingInput?
        private var pendingSelectionText: String?
        var appliedSelectionID: UUID?
        var dismissedContext: CompletionContext?
        private var context: CompletionContext?
        private var suggestions: [String] = []
        private var selectedIndex = 0
        private var isCompleting = false
        private let panel = MnemonicCandidatePanel()
        private var outsideMonitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var presentationID = UUID()
        private let content = MnemonicCandidateHostingView(rootView: MnemonicCandidateList(position: 0, words: [], selected: 0, choose: { _ in }, hover: { _ in }))

        private struct PendingInput {
            let text: String
            let modelBeforeEdit: String
        }

        struct CompletionContext: Equatable {
            let text: String
            let target: MnemonicCompletionTarget
        }

        init(_ parent: MnemonicTextEditor) {
            self.parent = parent
            super.init()
            panel.contentView = content
        }

        /// Synchronize native controls without publishing back into SwiftUI's update.
        func applyParentState(isEnabled: Bool) {
            guard isActive, let editor else { return }
            isUpdating = true
            defer { isUpdating = false }
            let modelText = parent.text
            let hasUnpublishedEdit = pendingInput.map {
                $0.text == editor.string && $0.modelBeforeEdit == modelText
            } ?? false
            if editor.string != modelText && !hasUnpublishedEdit && !editor.hasMarkedText() {
                pendingInput = nil
                pendingSelectionText = nil
                let oldSelection = editor.selectedRange()
                editor.string = modelText
                editor.setSelectedRange(NSRange(location: min(oldSelection.location, (modelText as NSString).length), length: 0))
            }
            if editor.isEditable != isEnabled { editor.isEditable = isEnabled }
            if let request = parent.selectionRequest, appliedSelectionID != request.id {
                appliedSelectionID = request.id
                if NSMaxRange(request.range) <= (editor.string as NSString).length {
                    editor.setSelectedRange(request.range)
                    editor.scrollRangeToVisible(request.range)
                    editor.window?.makeFirstResponder(editor)
                    dismissedContext = nil
                }
            }
            scheduleUpdate()
        }

        /// Both delegate notifications and nested NSHostingView updates can occur
        /// during a SwiftUI transaction. Coalesce them onto the next main-queue turn.
        private func scheduleUpdate() {
            guard isActive, !updateQueued else { return }
            updateQueued = true
            DispatchQueue.main.async { [weak self] in self?.flushUpdates() }
        }

        private func flushUpdates() {
            updateQueued = false
            guard isActive, let editor else { return }
            let input = pendingInput
            let selectionText = pendingSelectionText
            pendingInput = nil
            pendingSelectionText = nil
            if let input, editor.string == input.text,
               parent.text == input.modelBeforeEdit || parent.text == input.text {
                parent.onChange(input.text, editor.selectedRange())
            } else if let selectionText, editor.string == selectionText, parent.text == selectionText {
                parent.onSelection(editor.selectedRange())
            }
            updateCandidates()
        }

        func invalidate() {
            isActive = false
            pendingInput = nil
            pendingSelectionText = nil
            dismissCandidates()
        }

        func textDidChange(_ notification: Notification) {
            guard isActive, !isUpdating, let editor else { return }
            if !isCompleting { dismissedContext = nil }
            dismissCandidates()
            pendingInput = PendingInput(text: editor.string, modelBeforeEdit: parent.text)
            scheduleUpdate()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard isActive, !isUpdating, let editor else { return }
            if editor.hasMarkedText() { dismissCandidates(); return }
            // AppKit can restore text during undo/redo with only a selection
            // notification. Publish that restored value through the same queue.
            if editor.string != parent.text,
               editor.undoManager?.isUndoing == true || editor.undoManager?.isRedoing == true {
                dismissedContext = nil
                dismissCandidates()
                pendingInput = PendingInput(text: editor.string, modelBeforeEdit: parent.text)
            }
            pendingSelectionText = editor.string
            scheduleUpdate()
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard isActive, !isUpdating, let editor else { return }
            pendingSelectionText = editor.string
            scheduleUpdate()
        }

        func textDidEndEditing(_ notification: Notification) {
            if isActive && !isCompleting { scheduleUpdate() }
        }

        private func currentContext() -> CompletionContext? {
            guard let editor, let target = MnemonicCompletionTarget.atSelection(editor.selectedRange(), in: editor.string) else { return nil }
            return CompletionContext(text: editor.string, target: target)
        }

        func updateCandidates() {
            guard isActive, let editor, editor.isEditable, !editor.hasMarkedText(), editor.string == parent.text,
                  editor.window?.firstResponder === editor,
                  let next = currentContext(), next != dismissedContext, next.text == parent.inspectionText,
                  let inspection = parent.inspection, inspection.completionPosition == next.target.position,
                  !inspection.suggestions.isEmpty,
                  !(inspection.suggestions.count == 1 && inspection.suggestions[0] == next.target.word.lowercased()) else {
                dismissCandidates(); return
            }
            if context != next || suggestions != inspection.suggestions {
                dismissCandidates()
                selectedIndex = 0
                context = next
                suggestions = inspection.suggestions
            }
            refreshContent()
            guard let window = editor.window else { return }
            let caret = editor.firstRect(forCharacterRange: NSRange(location: editor.selectedRange().location, length: 0), actualRange: nil)
            let rect = editor.convert(window.convertFromScreen(caret), from: nil)
            guard editor.visibleRect.intersects(rect) else { dismissCandidates(); return }
            let size = NSSize(width: 300, height: 58 + suggestions.count * 30)
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let below = caret.minY - size.height - 6
            let y = below >= screen.minY + 8 ? below : caret.maxY + 6
            let origin = NSPoint(x: min(max(caret.minX, screen.minX + 8), screen.maxX - size.width - 8),
                                 y: min(max(y, screen.minY + 8), screen.maxY - size.height - 8))
            panel.appearance = editor.effectiveAppearance
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            if !panel.isVisible {
                let presentation = UUID()
                presentationID = presentation
                window.addChildWindow(panel, ordered: .above)
                panel.orderFront(nil)
                outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                    guard let self else { return event }
                    if event.window !== self.panel {
                        self.dismissedContext = self.currentContext()
                        self.dismissCandidates()
                    }
                    return event
                }
                resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.presentationID == presentation,
                              self.editor?.window?.isKeyWindow != true else { return }
                        self.dismissCandidates()
                    }
                }
            }
        }

        private func refreshContent() {
            content.rootView = MnemonicCandidateList(position: context?.target.position ?? 0, words: suggestions, selected: selectedIndex,
                choose: { [weak self] index in self?.accept(index) },
                hover: { [weak self] index in
                    guard let self, self.selectedIndex != index else { return }
                    self.selectedIndex = index
                    self.scheduleUpdate()
                })
        }

        func handle(_ event: NSEvent) -> Bool {
            guard let editor, !editor.hasMarkedText() else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command && [36, 76].contains(event.keyCode) {
                flushUpdates()
                dismissCandidates(); parent.onSearch(); return true
            }
            guard modifiers.isEmpty, panel.isVisible, !suggestions.isEmpty else { return false }
            switch event.keyCode {
            case 125: selectedIndex = min(selectedIndex + 1, suggestions.count - 1); refreshContent()
            case 126: selectedIndex = max(0, selectedIndex - 1); refreshContent()
            case 36, 76, 48: accept(selectedIndex)
            case 53: dismissedContext = currentContext(); dismissCandidates()
            default: return false
            }
            return true
        }

        private func accept(_ index: Int) {
            guard let editor, editor.string == parent.text, suggestions.indices.contains(index), let target = currentContext(), target == context,
                  let edit = MnemonicCompletionEdit.make(text: editor.string, position: target.target.position, word: suggestions[index]) else { return }
            isCompleting = true
            dismissCandidates()
            editor.window?.makeFirstResponder(editor)
            // Native insertion participates in the editor's undo stack.
            editor.insertText(edit.replacement, replacementRange: edit.range)
            editor.setSelectedRange(edit.selection)
            dismissedContext = currentContext()
            isCompleting = false
            NSAccessibility.post(element: editor, notification: .valueChanged)
        }

        func dismissCandidates() {
            presentationID = UUID()
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        }
    }
}

/// A nonactivating panel keeps all typing and navigation in the text editor.
private final class MnemonicCandidatePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    }
}

final class MnemonicNativeTextView: NSTextView {
    weak var coordinator: MnemonicTextEditor.Coordinator?
    override func keyDown(with event: NSEvent) {
        if coordinator?.handle(event) == true { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !hasMarkedText(), event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            if modifiers == .shift { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        super.keyDown(with: event)
    }
}

private final class MnemonicCandidateHostingView: NSHostingView<MnemonicCandidateList> {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MnemonicCandidateList: View {
    let position: Int
    let words: [String]
    let selected: Int
    let choose: (Int) -> Void
    let hover: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("第 \(position + 1) 词 · BIP39 英文词表")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 28)
            ForEach(words.indices, id: \.self) { index in
                Button { choose(index) } label: {
                    Text(words[index]).font(.system(size: 14, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 30)
                        .foregroundStyle(index == selected ? Color.white : Color.primary)
                        .background(index == selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { hover(index) } }
                .accessibilityLabel("补全为 \(words[index])")
                .accessibilityAddTraits(index == selected ? .isSelected : [])
            }
            Text("↑↓ 选择 · ↵ / Tab 补全 · Esc 关闭")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 30)
        }
        .padding(.horizontal, 6)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
