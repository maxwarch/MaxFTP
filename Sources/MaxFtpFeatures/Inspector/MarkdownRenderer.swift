import Foundation
import SwiftUI

/// Transforme du Markdown en texte mis en forme pour l'aperçu de l'inspecteur.
///
/// Le parseur de Foundation (`interpretedSyntax: .full`) reconnaît les blocs mais
/// `Text` ne les met pas en page : on insère ici les sauts de ligne, puces, numéros
/// et styles de titres. Le gras, l'italique, le code en ligne et les liens sont
/// rendus nativement par `Text`.
enum MarkdownRenderer {
    static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return AttributedString(markdown)
        }

        var result = AttributedString()
        var previous: PresentationIntent?
        var startedListItems: Set<Int> = []

        for run in parsed.runs {
            let intent = run.presentationIntent
            var piece = AttributedString(parsed[run.range])

            if intent?.components.first?.identity != previous?.components.first?.identity {
                if let previous {
                    result.append(AttributedString(separator(between: previous, and: intent)))
                }
                result.append(prefix(for: intent, startedListItems: &startedListItems))
            }
            style(&piece, for: intent)
            result.append(piece)
            previous = intent
        }
        return result
    }

    // MARK: Mise en page des blocs

    private static func separator(between previous: PresentationIntent, and next: PresentationIntent?) -> String {
        guard let next else { return "\n\n" }
        if let row = rowIdentity(of: previous), row == rowIdentity(of: next) { return "   │   " }
        if let table = identity(of: previous, where: isTable), table == identity(of: next, where: isTable) { return "\n" }
        if contains(previous, where: isListItem) && contains(next, where: isListItem) { return "\n" }
        return "\n\n"
    }

    private static func prefix(for intent: PresentationIntent?, startedListItems: inout Set<Int>) -> AttributedString {
        guard let intent else { return AttributedString() }
        var prefix = ""
        let listItems = intent.components.filter { isListItem($0.kind) }
        // Puce ou numéro uniquement au premier paragraphe de l'élément de liste.
        if let item = listItems.first, startedListItems.insert(item.identity).inserted {
            let depth = listItems.count - 1
            prefix += String(repeating: "    ", count: depth)
            if case .listItem(let ordinal) = item.kind, isOrdered(item, in: intent) {
                prefix += "\(ordinal). "
            } else {
                prefix += depth.isMultiple(of: 2) ? "•  " : "◦  "
            }
        }
        if contains(intent, where: isBlockQuote) {
            prefix = "▎ " + prefix
        }
        var attributed = AttributedString(prefix)
        if contains(intent, where: isBlockQuote) { attributed.foregroundColor = .secondary }
        return attributed
    }

    private static func style(_ piece: inout AttributedString, for intent: PresentationIntent?) {
        guard let intent else { return }
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                piece.font = switch level {
                case 1: .title.bold()
                case 2: .title2.bold()
                case 3: .title3.bold()
                default: .headline
                }
                return
            case .codeBlock:
                // Le parseur conserve le dernier saut de ligne du bloc : le séparateur s'en charge.
                if piece.characters.last == "\n" {
                    piece.characters.removeLast()
                }
                piece.font = .system(.callout, design: .monospaced)
                piece.backgroundColor = Color.secondary.opacity(0.12)
                return
            case .tableHeaderRow:
                piece.font = .body.bold()
                return
            case .thematicBreak, .blockQuote:
                piece.foregroundColor = .secondary
                return
            default:
                continue
            }
        }
    }

    // MARK: Inspection des intentions

    private static func contains(_ intent: PresentationIntent, where predicate: (PresentationIntent.Kind) -> Bool) -> Bool {
        intent.components.contains { predicate($0.kind) }
    }

    private static func identity(of intent: PresentationIntent, where predicate: (PresentationIntent.Kind) -> Bool) -> Int? {
        intent.components.first { predicate($0.kind) }?.identity
    }

    private static func rowIdentity(of intent: PresentationIntent) -> Int? {
        identity(of: intent) { kind in
            switch kind {
            case .tableRow, .tableHeaderRow: true
            default: false
            }
        }
    }

    /// La liste qui contient directement cet élément est-elle numérotée ?
    private static func isOrdered(_ item: PresentationIntent.IntentType, in intent: PresentationIntent) -> Bool {
        guard let index = intent.components.firstIndex(of: item), index + 1 < intent.components.count else { return false }
        if case .orderedList = intent.components[index + 1].kind { return true }
        return false
    }

    private static func isListItem(_ kind: PresentationIntent.Kind) -> Bool {
        if case .listItem = kind { return true }
        return false
    }

    private static func isBlockQuote(_ kind: PresentationIntent.Kind) -> Bool {
        if case .blockQuote = kind { return true }
        return false
    }

    private static func isTable(_ kind: PresentationIntent.Kind) -> Bool {
        if case .table = kind { return true }
        return false
    }
}
