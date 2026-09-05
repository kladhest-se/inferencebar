import AppKit
import Foundation

/// The key code + modifier combination that shows/hides the Chat window
/// from anywhere, and how it's persisted and displayed. Kept as its own
/// pure-ish type — no dependency on AppStore or InferenceBarDelegate —
/// so it can be read from a nonisolated context (AppKit's global/local
/// event monitor closures in InferenceBarDelegate run off the main actor)
/// and so its comparison/formatting logic can be unit tested without any
/// of the app's actor-isolated state.
enum GlobalHotkey {
    // kVK_Space. Option+Command+Space is the combo this app always used
    // before the shortcut became customizable, so upgrading users see no
    // behavior change until they explicitly record a new one in Settings.
    static let defaultKeyCode: UInt16 = 49
    static let defaultModifierFlags: NSEvent.ModifierFlags = [.option, .command]

    private static let keyCodeDefaultsKey = "hotkeyKeyCode"
    private static let modifierFlagsDefaultsKey = "hotkeyModifierFlags"

    // Read/written directly against UserDefaults.standard (not through
    // AppStore.shared, a @MainActor type) so these stay safe to call from
    // InferenceBarDelegate's nonisolated event-monitor closures. AppStore
    // mirrors these into its own @Observable stored properties so Settings
    // UI updates as they change; those properties write through to here.
    static var keyCode: UInt16 {
        get {
            guard let stored = UserDefaults.standard.object(forKey: keyCodeDefaultsKey) as? Int else { return defaultKeyCode }
            return UInt16(clamping: stored)
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: keyCodeDefaultsKey) }
    }

    static var modifierFlags: NSEvent.ModifierFlags {
        get {
            guard let stored = UserDefaults.standard.object(forKey: modifierFlagsDefaultsKey) as? Int else { return defaultModifierFlags }
            return NSEvent.ModifierFlags(rawValue: UInt(stored))
        }
        set { UserDefaults.standard.set(Int(newValue.rawValue), forKey: modifierFlagsDefaultsKey) }
    }

    /// Modifiers the recorder pays attention to at all — Fn and other
    /// device-dependent bits are ignored so a recorded combo compares
    /// cleanly against `NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)`.
    static let recordableModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Pure comparison, deliberately taking the event's raw key code and
    /// modifier flags rather than an `NSEvent` itself, so it's testable
    /// without constructing one.
    static func matches(eventKeyCode: UInt16, eventModifierFlags: NSEvent.ModifierFlags, keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        eventKeyCode == keyCode && eventModifierFlags.intersection(.deviceIndependentFlagsMask) == modifierFlags
    }

    // MARK: - Display

    // Best-effort US ANSI layout names for the keys someone is actually
    // likely to record a shortcut on. Not layout-aware (translating a raw
    // key code through the user's actual keyboard layout needs Carbon's
    // UCKeyTranslate), but every key here reads the same across the
    // common layouts this app targets, and anything unmapped still shows
    // as "Key <code>" rather than nothing at all.
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
        76: "Enter", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// e.g. "⌥⌘Space" — modifier order matches macOS's own menu-item
    /// convention (Control, Option, Shift, Command).
    static func displayString(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        parts.append(keyNames[keyCode] ?? "Key \(keyCode)")
        return parts.joined()
    }
}
