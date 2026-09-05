import Foundation
import XCTest
@testable import InferenceBar

/// Tests for core app lifecycle decisions: whether the default profile
/// should auto-start at launch, and whether a GitHub release tag counts as
/// an available update.
///
/// Previously an `InferenceBarUITests` file driving the real app with
/// `XCUIApplication` to check that windows opened and a status bar item
/// and a dock icon existed. As explained in SettingsTests.swift, none of
/// that could ever run under `swift test`; window-opening and dock-icon
/// visibility are also driven by `NSApp.windows`/`NSApp.setActivationPolicy`
/// state that only a real running app has, with no pure equivalent to test
/// in isolation. Rewritten to test the two decisions that actually gate
/// what happens right after launch: `DefaultProfileStartupPolicy` (only
/// partly covered by DownloadAndModelTests.swift, which didn't exercise
/// the `.downloading`/`.starting`/`.failed` lifecycle states) and
/// `AppUpdatePolicy` edge cases beyond its existing happy-path coverage.
final class BasicAppFlowTests: XCTestCase {

    func testDefaultProfileStartupIsBlockedWhileAnyProfileIsBusy() {
        for lifecycle: ServerLifecycle in [.starting, .downloading, .running, .stopping] {
            XCTAssertFalse(
                DefaultProfileStartupPolicy.shouldStart(enabled: true, defaultProfileExists: true, lifecycle: lifecycle),
                "\(lifecycle) should never be interrupted by an auto-start of the default profile"
            )
        }
    }

    func testDefaultProfileStartupIsAllowedWhenIdle() {
        XCTAssertTrue(DefaultProfileStartupPolicy.shouldStart(enabled: true, defaultProfileExists: true, lifecycle: .stopped))
        XCTAssertTrue(DefaultProfileStartupPolicy.shouldStart(enabled: true, defaultProfileExists: true, lifecycle: .failed("previous run crashed")), "A prior failure shouldn't permanently block auto-start on the next launch")
    }

    func testDefaultProfileStartupRequiresBothTheToggleAndAConfiguredProfile() {
        XCTAssertFalse(DefaultProfileStartupPolicy.shouldStart(enabled: false, defaultProfileExists: true, lifecycle: .stopped))
        XCTAssertFalse(DefaultProfileStartupPolicy.shouldStart(enabled: true, defaultProfileExists: false, lifecycle: .stopped))
        XCTAssertFalse(DefaultProfileStartupPolicy.shouldStart(enabled: false, defaultProfileExists: false, lifecycle: .stopped))
    }

    func testUpdateCheckFindsNoUpdateWhenCurrentVersionIsUnparseable() {
        XCTAssertNil(AppUpdatePolicy.newestUpdate(tags: ["v1.0", "v2.0"], currentVersion: "not-a-version"), "With no way to know the running version, offering an update would just be a guess")
    }

    func testUpdateCheckIgnoresTagsNoNewerThanCurrent() {
        XCTAssertNil(AppUpdatePolicy.newestUpdate(tags: ["v0.5", "v0.4", "0.3"], currentVersion: "0.5"), "A tag equal to or older than the current version is not an update")
    }

    func testUpdateCheckPicksTheHighestQualifyingTagNotJustTheLastOne() {
        // Deliberately out of order and interleaved with a malformed tag, to
        // confirm this compares versions rather than trusting list order.
        XCTAssertEqual(AppUpdatePolicy.newestUpdate(tags: ["v0.7", "not-a-tag", "v0.6", "v0.9"], currentVersion: "0.5"), "v0.9")
    }
}
