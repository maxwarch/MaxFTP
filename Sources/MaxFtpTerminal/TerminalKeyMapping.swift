import AppKit
import Carbon.HIToolbox

/// Correspondances clavier macOS → séquences d'octets pour le terminal embarqué :
/// pavé numérique (contournant l'encodage Kitty de SwiftTerm) et raccourcis d'édition.
enum TerminalKeyMapping {
    private static let keypadFallbackCharacters: [Int: String] = [
        kVK_ANSI_Keypad0: "0",
        kVK_ANSI_Keypad1: "1",
        kVK_ANSI_Keypad2: "2",
        kVK_ANSI_Keypad3: "3",
        kVK_ANSI_Keypad4: "4",
        kVK_ANSI_Keypad5: "5",
        kVK_ANSI_Keypad6: "6",
        kVK_ANSI_Keypad7: "7",
        kVK_ANSI_Keypad8: "8",
        kVK_ANSI_Keypad9: "9",
        kVK_ANSI_KeypadDecimal: ".",
        kVK_ANSI_KeypadDivide: "/",
        kVK_ANSI_KeypadMultiply: "*",
        kVK_ANSI_KeypadMinus: "-",
        kVK_ANSI_KeypadPlus: "+",
        kVK_ANSI_KeypadEquals: "=",
    ]

    /// Retourne les octets à envoyer pour une touche du pavé numérique, ou `nil` sinon.
    static func keypadBytes(keyCode: UInt16, characters: String?) -> [UInt8]? {
        let code = Int(keyCode)
        if code == kVK_ANSI_KeypadEnter {
            return [0x0d]
        }
        guard let fallback = keypadFallbackCharacters[code] else { return nil }
        if let characters, !characters.isEmpty, characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f }) {
            return Array(characters.utf8)
        }
        return Array(fallback.utf8)
    }

    /// Retourne la séquence d'octets pour les raccourcis macOS de déplacement/suppression par mot ou ligne.
    static func shortcutBytes(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> [UInt8]? {
        let relevant = modifiers.intersection([.command, .option, .control])
        let code = Int(keyCode)

        if relevant == .command {
            switch code {
            case kVK_LeftArrow: return [0x01]   // Ctrl+A : début de ligne
            case kVK_RightArrow: return [0x05]  // Ctrl+E : fin de ligne
            case kVK_Delete: return [0x15]      // Ctrl+U : effacer jusqu'au début de ligne
            default: return nil
            }
        }

        if relevant == .option {
            switch code {
            case kVK_LeftArrow: return [0x1b, 0x62]   // ESC b : mot précédent
            case kVK_RightArrow: return [0x1b, 0x66]  // ESC f : mot suivant
            case kVK_Delete: return [0x1b, 0x7f]      // ESC DEL : effacer le mot précédent
            default: return nil
            }
        }

        return nil
    }

    /// Indique si la frappe correspond au raccourci macOS d'effacement de la console (`⌘K`).
    static func isClearConsoleShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        return relevant == .command && Int(keyCode) == kVK_ANSI_K
    }
}
