import Foundation
import XCTest
@testable import InferenceBar

/// Tests for how raw process output bytes get assembled into the lines
/// the Logs window displays.
///
/// Previously an `InferenceBarUITests` file driving the real Logs window
/// with `XCUIApplication`, asserting on a Filter dropdown with All/Debug/
/// Info/Warn/Error options, an Autoscroll toggle, and an "Export logs"
/// button — none of which exist in the real `LogsView` (it has Copy,
/// Clear, "Reveal log file", and "Stop engine"; see NewFeaturesTests.swift
/// for the "Reveal log file" button's era). As explained in
/// SettingsTests.swift, none of it could ever actually run under
/// `swift test` anyway. Rewritten to test `ProcessLogLineBuffer`, the byte
/// assembler every line in that window passes through — specifically the
/// carriage-return handling DownloadAndModelTests.swift's existing
/// multi-byte-UTF-8 case doesn't touch, which matters because llama.cpp's
/// own progress lines use bare `\r` to redraw in place.
final class LogsTests: XCTestCase {

    func testCarriageReturnEndsALineJustLikeLineFeed() {
        var buffer = ProcessLogLineBuffer()
        var lines: [String] = []
        for byte in Array("warning\rerror\n".utf8) {
            if let line = buffer.append(byte) { lines.append(line) }
        }
        XCTAssertEqual(lines, ["warning\r", "error\n"])
        XCTAssertNil(buffer.flush())
    }

    func testCarriageReturnLineFeedPairEmitsTwoSeparateLines() {
        // \r and \n are each their own line terminator here, so a Windows-
        // style CRLF ending doesn't get merged into a single logical line —
        // it flushes once at the \r and again, with just the \n, right after.
        var buffer = ProcessLogLineBuffer()
        var lines: [String] = []
        for byte in Array("line\r\n".utf8) {
            if let line = buffer.append(byte) { lines.append(line) }
        }
        XCTAssertEqual(lines, ["line\r", "\n"])
    }

    func testRepeatedCarriageReturnsUsedForInPlaceProgressRedraws() {
        var buffer = ProcessLogLineBuffer()
        var lines: [String] = []
        for byte in Array("10%\r20%\r30%\n".utf8) {
            if let line = buffer.append(byte) { lines.append(line) }
        }
        XCTAssertEqual(lines, ["10%\r", "20%\r", "30%\n"])
    }

    func testFlushOnlyReturnsSomethingWhenBytesAreStillPending() {
        var buffer = ProcessLogLineBuffer()
        XCTAssertNil(buffer.flush(), "Nothing has been appended yet")
        _ = buffer.append(UInt8(ascii: "x"))
        XCTAssertEqual(buffer.flush(), "x")
        XCTAssertNil(buffer.flush(), "A second flush right after the first has nothing left to return")
    }
}
