/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import SwiftUI

/// A deliberately small code editor: syntax colors, tabs and matching indentation,
/// without completion popovers, diagnostics, or language-server integration.
struct NoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fileType: NoteFileType
    let autofocus: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NoteNativeTextView()
        textView.shouldAutofocus = autofocus
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.enabledTextCheckingTypes = 0
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applyAppearance(fileType: fileType)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteNativeTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingUpdate = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
            context.coordinator.isApplyingUpdate = false
        }
        context.coordinator.applyAppearance(fileType: fileType)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        weak var textView: NoteNativeTextView?
        var isApplyingUpdate = false
        private var currentFileType: NoteFileType?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingUpdate, let textView = notification.object as? NoteNativeTextView else { return }
            text = textView.string
            applyHighlighting(to: textView, fileType: currentFileType ?? .plainText)
        }

        func applyAppearance(fileType: NoteFileType) {
            guard let textView else { return }
            currentFileType = fileType
            textView.usesCodeEditingBehavior = fileType != .plainText
            applyHighlighting(to: textView, fileType: fileType)
        }

        private func applyHighlighting(to textView: NSTextView, fileType: NoteFileType) {
            guard let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let fullRange = NSRange(location: 0, length: storage.length)
            let font = fileType == .plainText
                ? NSFont.systemFont(ofSize: 13)
                : NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

            storage.beginEditing()
            storage.setAttributes([
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraphStyle(for: fileType)
            ], range: fullRange)

            guard fileType != .plainText, storage.length > 0 else {
                storage.endEditing()
                textView.setSelectedRange(selection)
                return
            }

            let source = storage.string
            apply(pattern: keywordPattern(for: fileType), color: .systemPink, source: source, storage: storage)
            apply(pattern: #"\b\d+(?:\.\d+)?\b"#, color: .systemOrange, source: source, storage: storage)
            apply(pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: .systemGreen, source: source, storage: storage)

            if fileType == .html {
                apply(pattern: #"</?[A-Za-z][^>]*>"#, color: .systemBlue, source: source, storage: storage)
            } else if fileType == .markdown {
                apply(pattern: #"(?m)^(?:#{1,6}|>|[-*+]\s)\s?.*$"#, color: .systemBlue, source: source, storage: storage)
                apply(pattern: #"`[^`]+`"#, color: .systemOrange, source: source, storage: storage)
            } else if fileType == .json {
                apply(pattern: #"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, color: .systemBlue, source: source, storage: storage)
            }

            apply(pattern: commentPattern(for: fileType), color: .systemGray, source: source, storage: storage)
            storage.endEditing()
            textView.setSelectedRange(selection)
        }

        private func paragraphStyle(for fileType: NoteFileType) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = fileType == .plainText ? 4 : 2
            if fileType != .plainText {
                style.defaultTabInterval = 28
                style.tabStops = []
            }
            return style
        }

        private func apply(pattern: String?, color: NSColor, source: String, storage: NSTextStorage) {
            guard let pattern, !pattern.isEmpty,
                  let expression = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in expression.matches(in: source, range: range) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        private func commentPattern(for type: NoteFileType) -> String? {
            switch type {
            case .python, .shell, .yaml: return #"(?m)#.*$"#
            case .sql: return #"(?m)--.*$|/\*[\s\S]*?\*/"#
            case .html, .markdown: return #"<!--[\s\S]*?-->"#
            case .css, .javascript, .typescript, .swift, .json, .c, .cpp, .java, .go, .rust:
                return #"(?m)//.*$|/\*[\s\S]*?\*/"#
            case .plainText: return nil
            }
        }

        private func keywordPattern(for type: NoteFileType) -> String? {
            let words: [String]
            switch type {
            case .python:
                words = ["and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "None", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
            case .javascript, .typescript:
                words = ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"]
            case .swift:
                words = ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import", "in", "init", "let", "nil", "protocol", "repeat", "return", "self", "some", "struct", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"]
            case .c, .cpp, .java:
                words = ["auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default", "delete", "do", "double", "else", "enum", "extends", "false", "final", "float", "for", "if", "implements", "import", "int", "interface", "long", "namespace", "new", "null", "private", "protected", "public", "return", "short", "static", "struct", "super", "switch", "template", "this", "throw", "true", "try", "typedef", "using", "virtual", "void", "while"]
            case .go:
                words = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]
            case .rust:
                words = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
            case .sql:
                words = ["ALTER", "AND", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "CREATE", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FROM", "GROUP", "HAVING", "IN", "INDEX", "INSERT", "INTO", "IS", "JOIN", "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "SELECT", "SET", "TABLE", "THEN", "UNION", "UPDATE", "VALUES", "WHEN", "WHERE"]
            case .json:
                words = ["true", "false", "null"]
            case .css:
                words = ["important", "inherit", "initial", "unset", "none", "auto"]
            case .yaml:
                words = ["true", "false", "null", "yes", "no", "on", "off"]
            case .html, .markdown, .shell, .plainText:
                words = []
            }
            guard !words.isEmpty else { return nil }
            return #"(?i)\b(?:"# + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#
        }
    }
}

final class NoteNativeTextView: NSTextView {
    var usesCodeEditingBehavior = false
    var shouldAutofocus = false
    private var didRequestInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard shouldAutofocus, !didRequestInitialFocus, let window else { return }
        didRequestInitialFocus = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func complete(_ sender: Any?) {
        // This editor intentionally has no completion UI.
    }

    override func insertTab(_ sender: Any?) {
        if usesCodeEditingBehavior {
            insertText("    ", replacementRange: selectedRange())
        } else {
            super.insertTab(sender)
        }
    }

    override func insertNewline(_ sender: Any?) {
        guard usesCodeEditingBehavior else {
            super.insertNewline(sender)
            return
        }

        let nsText = string as NSString
        let cursor = selectedRange().location
        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let line = nsText.substring(with: NSRange(location: lineRange.location, length: max(0, cursor - lineRange.location)))
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        insertText("\n\(indentation)", replacementRange: selectedRange())
    }
}
