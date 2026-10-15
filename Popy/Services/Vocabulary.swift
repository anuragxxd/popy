import AppKit
import os

enum Log {
    static let dictation = Logger(subsystem: "com.popy.app", category: "dictation")
}

/// The user's own words: names, jargon, and product terms the speech engine
/// keeps getting wrong.
///
/// Edited as plain text, one entry per line:
///
///     Kubernetes            a term: spelled exactly like this
///     pop e -> Popy         a replacement: heard as "pop e", written "Popy"
///     # comment
///
/// Terms are passed to Whisper as hints and also fix casing in any
/// transcript ("github" → "GitHub"). Replacements apply to whole words,
/// ignoring case. Apple's SpeechTranscriber takes no vocabulary hints
/// (contextual strings only reach DictationTranscriber), so on Macs using
/// Apple's model replacements are what fix a word it consistently mishears.
///
/// This is the only rewriting a transcript ever gets, and only ever what the
/// user wrote here.
struct Vocabulary {

    struct Replacement {
        let heard: String
        let written: String
    }

    let terms: [String]
    let replacements: [Replacement]

    static let separator = "->"

    static var current: Vocabulary {
        parse(PreferencesManager.shared.vocabularyText)
    }

    var isEmpty: Bool { terms.isEmpty && replacements.isEmpty }

    static func parse(_ text: String) -> Vocabulary {
        var terms: [String] = []
        var replacements: [Replacement] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if let range = line.range(of: separator) {
                let heard = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let written = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !heard.isEmpty else { continue }
                replacements.append(Replacement(heard: heard, written: written))
            } else {
                terms.append(line)
            }
        }

        return Vocabulary(terms: terms, replacements: replacements)
    }

    /// The transcript with the user's replacements and spellings applied.
    func apply(to transcript: String) -> String {
        var text = transcript

        // Longest first, so "pop e dot com" wins over "pop e".
        for replacement in replacements.sorted(by: { $0.heard.count > $1.heard.count }) {
            text = Self.replaceWholeWords(replacement.heard, with: replacement.written, in: text)
        }
        for term in terms.sorted(by: { $0.count > $1.count }) {
            text = Self.replaceWholeWords(term, with: term, in: text)
        }

        // A replacement to nothing can leave doubled or dangling spaces.
        if replacements.contains(where: { $0.written.isEmpty }) {
            text = text.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Words worth priming Whisper with: the terms, and what replacements write.
    var hints: [String] {
        var seen = Set<String>()
        return (terms + replacements.map(\.written)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Matches `phrase` as whole words, case-insensitively, tolerating any
    /// run of whitespace between its words.
    private static func replaceWholeWords(_ phrase: String, with replacement: String, in text: String) -> String {
        let words = phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return text }

        let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}

// MARK: - Editor

/// A plain-text editor for `Vocabulary`. Saves as you type.
final class VocabularyWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    static let shared = VocabularyWindowController()

    private let textView = NSTextView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Popy Vocabulary"
        window.minSize = NSSize(width: 320, height: 240)
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        textView.string = PreferencesManager.shared.vocabularyText
        // An LSUIElement app has to bring itself forward for the window to take focus.
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    private func buildContent(in window: NSWindow) {
        let help = NSTextField(wrappingLabelWithString:
            "One per line. A word or name on its own is spelled exactly as you write it. "
            + "Use \"heard -> written\" to fix a word Popy keeps mishearing."
        )
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView

        let example = NSTextField(labelWithString: "e.g.  Kubernetes   ·   pop e -> Popy   ·   # comment")
        example.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        example.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [help, scroll, example])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            help.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])
    }

    func textDidChange(_ notification: Notification) {
        PreferencesManager.shared.vocabularyText = textView.string
    }

    func windowWillClose(_ notification: Notification) {
        PreferencesManager.shared.vocabularyText = textView.string
    }
}
