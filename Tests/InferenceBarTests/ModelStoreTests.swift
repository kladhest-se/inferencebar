import Foundation
import XCTest
@testable import InferenceBar

/// Tests for the Model Store's area/category wiring.
///
/// Previously an `InferenceBarUITests` file driving the real Model Store
/// window with `XCUIApplication`. As explained in SettingsTests.swift,
/// SwiftPM has no UI-Testing-Bundle product type, so `XCUIApplication`
/// could never actually run under `swift test` regardless of how the app
/// was launched. Rewritten to test `ModelArea`'s pure, side-effect-free
/// mapping from sidebar entry to search categories — the logic that
/// decides which "Discover"/"Curated"/"Categories" section each area
/// belongs to and what it searches for. Model-catalog scanning, hardware
/// fit, and runtime-availability logic already have deep coverage in
/// DownloadAndModelTests.swift.
final class ModelStoreTests: XCTestCase {

    func testDownloadedAreaHasNoSearchCategories() {
        // "Downloaded" lists what's already on disk locally; it never
        // drives a Hugging Face category search.
        XCTAssertTrue(ModelArea.downloaded.categories.isEmpty)
    }

    func testDiscoverAndCuratedAreasEachMapToExactlyOneCategory() {
        let singleCategoryAreas: [ModelArea] = [
            .trending, .mostDownloaded, .recentlyUpdated,
            .recommendedCoding, .recommendedChat, .recommendedSystems,
            .recommendedHomeAutomation, .recommendedAppleSilicon
        ]
        for area in singleCategoryAreas {
            XCTAssertEqual(area.categories.count, 1, "\(area.rawValue) should drive a single, specific category search")
        }
    }

    func testFormatCategoriesAlwaysIncludeAllAsTheFirstOption() {
        // The six broad-format areas (Text & Chat, Coding, Multimodal,
        // Vision, Audio, Languages) each layer their specific task
        // categories on top of the universal "All" category, so switching
        // into one never hides results that don't carry the narrower tag.
        let formatAreas: [ModelArea] = [.text, .coding, .multimodal, .vision, .audio, .languages]
        for area in formatAreas {
            XCTAssertGreaterThan(area.categories.count, 1, "\(area.rawValue) should offer more than just 'All'")
            XCTAssertEqual(area.categories.first, ModelCategory.all, "\(area.rawValue) should always include the 'All' category first")
        }
    }

    func testEveryAreaHasAUniqueSidebarIdentity() {
        // ModelArea.rawValue is what SwiftUI's List uses as each sidebar
        // row's identity; a collision would make two different areas
        // behave as one selection.
        let rawValues = ModelArea.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
    }

}
