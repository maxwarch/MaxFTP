import AppKit
import Carbon.HIToolbox
@testable import MaxFtpTerminal
import Testing

@Suite("Raccourcis et pavé numérique du terminal")
struct TerminalKeyMappingTests {
    @Test func mapsNumericKeypadKeysToASCII() {
        #expect(TerminalKeyMapping.keypadBytes(keyCode: UInt16(kVK_ANSI_Keypad0), characters: "0") == [0x30])
        #expect(TerminalKeyMapping.keypadBytes(keyCode: UInt16(kVK_ANSI_Keypad5), characters: nil) == [0x35])
        #expect(TerminalKeyMapping.keypadBytes(keyCode: UInt16(kVK_ANSI_KeypadDecimal), characters: ".") == [0x2e])
        #expect(TerminalKeyMapping.keypadBytes(keyCode: UInt16(kVK_ANSI_KeypadPlus), characters: "+") == [0x2b])
        #expect(TerminalKeyMapping.keypadBytes(keyCode: UInt16(kVK_ANSI_KeypadEnter), characters: "\r") == [0x0d])
        #expect(TerminalKeyMapping.keypadBytes(keyCode: UInt16(kVK_ANSI_A), characters: "a") == nil)
    }

    @Test func mapsWordAndLineNavigationShortcuts() {
        // Saut de mot : ⌥← / ⌥→ / ⌥⌫
        #expect(TerminalKeyMapping.shortcutBytes(keyCode: UInt16(kVK_LeftArrow), modifiers: .option) == [0x1b, 0x62])
        #expect(TerminalKeyMapping.shortcutBytes(keyCode: UInt16(kVK_RightArrow), modifiers: .option) == [0x1b, 0x66])
        #expect(TerminalKeyMapping.shortcutBytes(keyCode: UInt16(kVK_Delete), modifiers: .option) == [0x1b, 0x7f])

        // Début / fin de ligne : ⌘← / ⌘→ / ⌘⌫
        #expect(TerminalKeyMapping.shortcutBytes(keyCode: UInt16(kVK_LeftArrow), modifiers: .command) == [0x01])
        #expect(TerminalKeyMapping.shortcutBytes(keyCode: UInt16(kVK_RightArrow), modifiers: .command) == [0x05])
        #expect(TerminalKeyMapping.shortcutBytes(keyCode: UInt16(kVK_Delete), modifiers: .command) == [0x15])

        // Sans modificateur : pas d'interception.
        #expect(TerminalKeyMapping.shortcutBytes(keyCode: UInt16(kVK_LeftArrow), modifiers: []) == nil)
    }
}
