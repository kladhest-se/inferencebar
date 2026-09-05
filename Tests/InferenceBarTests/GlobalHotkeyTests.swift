import AppKit
import Foundation
import XCTest
@testable import InferenceBar

/// Tests for the pure parts of the customizable global shortcut: matching
/// a raw key code/modifier pair against the recorded combo, and formatting
/// a combo for display in Settings. Deliberately doesn't touch
/// `GlobalHotkey.keyCode`/`.modifierFlags` themselves, since those read
/// and write the real `UserDefaults.standard` and would leak state across
/// test runs and other suites.
final class GlobalHotkeyTests: XCTestCase {

    func testMatchesRequiresBothKeyCodeAndModifiersToLineUp() {
        XCTAssertTrue(GlobalHotkey.matches(eventKeyCode: 49, eventModifierFlags: [.option, .command], keyCode: 49, modifierFlags: [.option, .command]))
        XCTAssertFalse(GlobalHotkey.matches(eventKeyCode: 49, eventModifierFlags: [.option, .command], keyCode: 12, modifierFlags: [.option, .command]), "Right modifiers, wrong key")
        XCTAssertFalse(GlobalHotkey.matches(eventKeyCode: 49, eventModifierFlags: [.command], keyCode: 49, modifierFlags: [.option, .command]), "Right key, missing a modifier")
        XCTAssertFalse(GlobalHotkey.matches(eventKeyCode: 49, eventModifierFlags: [.option, .command, .shift], keyCode: 49, modifierFlags: [.option, .command]), "An extra held-down modifier shouldn't still match")
    }

    func testMatchesIgnoresDeviceDependentModifierBits() {
        // NSEvent.modifierFlags can carry extra device-dependent bits (the
        // lower 16 bits, outside .deviceIndependentFlagsMask) alongside
        // the ones that make up a shortcut; only the device-independent
        // subset should ever be compared.
        let withExtraBits = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags([.option, .command]).rawValue | 0x1)
        XCTAssertTrue(GlobalHotkey.matches(eventKeyCode: 49, eventModifierFlags: withExtraBits, keyCode: 49, modifierFlags: [.option, .command]))
    }

    func testDisplayStringOrdersModifiersLikeMacOSMenus() {
        XCTAssertEqual(GlobalHotkey.displayString(keyCode: 49, modifierFlags: [.option, .command]), "⌥⌘Space")
        XCTAssertEqual(GlobalHotkey.displayString(keyCode: 0, modifierFlags: [.control, .option, .shift, .command]), "⌃⌥⇧⌘A", "Control, Option, Shift, Command — always in that order regardless of insertion order")
    }

    func testDisplayStringNamesCommonSpecialKeys() {
        XCTAssertEqual(GlobalHotkey.displayString(keyCode: 53, modifierFlags: [.command]), "⌘Escape")
        XCTAssertEqual(GlobalHotkey.displayString(keyCode: 123, modifierFlags: [.command]), "⌘←")
        XCTAssertEqual(GlobalHotkey.displayString(keyCode: 122, modifierFlags: [.control]), "⌃F1")
    }

    func testDisplayStringFallsBackToKeyCodeForUnmappedKeys() {
        XCTAssertEqual(GlobalHotkey.displayString(keyCode: 9999, modifierFlags: [.command]), "⌘Key 9999")
    }

    func testDefaultComboIsOptionCommandSpace() {
        XCTAssertEqual(GlobalHotkey.defaultKeyCode, 49)
        XCTAssertEqual(GlobalHotkey.defaultModifierFlags, [.option, .command])
    }
}
