import Foundation
import XCTest
@testable import InferenceBar

/// Tests for the status text InferenceBar shows about itself — the menu
/// bar title over the running model, and the lifecycle labels that back
/// it, the Chat window's status line, and the Logs window's header.
///
/// Previously an `InferenceBarUITests` file that clicked through the
/// status-bar menu and asserted windows/menu items merely existed (many
/// guarded by `if item.exists { item.click() }`, which passes whether or
/// not the item is actually there). As explained in SettingsTests.swift,
/// none of it could ever run under `swift test` regardless. Rewritten to
/// test the pure status-presentation logic those menus and windows read
/// from: `ServerLifecycle.label` and `MenuBarLifecyclePresentation`. The
/// `.stopping` branch and `locksProfileSelection` already have coverage in
/// DownloadAndModelTests.swift.
final class AppStoreTests: XCTestCase {

    func testServerLifecycleLabelsCoverEveryState() {
        XCTAssertEqual(ServerLifecycle.stopped.label, "Stopped")
        XCTAssertEqual(ServerLifecycle.stopping.label, "Stopping…")
        XCTAssertEqual(ServerLifecycle.starting.label, "Starting…")
        XCTAssertEqual(ServerLifecycle.downloading.label, "Downloading model…")
        XCTAssertEqual(ServerLifecycle.running.label, "Running")
        XCTAssertEqual(ServerLifecycle.failed("executable not found").label, "Failed: executable not found")
    }

    func testMenuBarTitleDuringStartingAndDownloading() {
        XCTAssertEqual(
            MenuBarLifecyclePresentation.profileTitle(name: "Qwen", lifecycle: .starting, activity: .idle, isSending: false),
            "Starting… · Qwen"
        )
        XCTAssertEqual(
            MenuBarLifecyclePresentation.profileTitle(name: "Qwen", lifecycle: .downloading, activity: .idle, isSending: false),
            "Downloading… · Qwen"
        )
    }

    func testMenuBarTitleShowsEngineActivityOnlyWhileSending() {
        XCTAssertEqual(
            MenuBarLifecyclePresentation.profileTitle(name: "Qwen", lifecycle: .running, activity: .reasoning, isSending: true),
            "Reasoning · Qwen"
        )
        XCTAssertEqual(
            MenuBarLifecyclePresentation.profileTitle(name: "Qwen", lifecycle: .running, activity: .idle, isSending: true),
            "Working · Qwen",
            "An empty activity label while actively sending should still say something is happening"
        )
        XCTAssertEqual(
            MenuBarLifecyclePresentation.profileTitle(name: "Qwen", lifecycle: .running, activity: .reasoning, isSending: false),
            "Qwen",
            "With nothing in flight, the title is just the profile name, regardless of the last known activity"
        )
    }
}
