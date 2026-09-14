import OpenWaterCore
import UIKit
import XCTest
@testable import openWater

/// What the clipboard import makes of what it finds.
///
/// Against a private, named pasteboard rather than the general one: reading
/// the general pasteboard from a test process raises the system's paste
/// prompt, which nothing in a test can answer.
@MainActor
final class ClipboardImportTests: XCTestCase {

    private func pasteboard() -> UIPasteboard {
        UIPasteboard.withUniqueName()
    }

    private let gpx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test"><trk><trkseg>
    <trkpt lat="41.03" lon="-71.92"><time>2026-09-13T22:14:09Z</time></trkpt>
    <trkpt lat="41.031" lon="-71.921"><time>2026-09-13T22:14:10Z</time></trkpt>
    </trkseg></trk></gpx>
    """

    func testEmptyClipboardIsNothing() {
        let board = pasteboard()
        XCTAssertEqual(ClipboardImportSheet.read(board), .nothing)
    }

    func testCopiedGPXTextIsFound() {
        let board = pasteboard()
        board.string = gpx
        guard case .track(let data, let format) = ClipboardImportSheet.read(board) else {
            return XCTFail("GPX text on the clipboard was not recognised")
        }
        XCTAssertEqual(format, .gpx)
        XCTAssertEqual(String(data: data, encoding: .utf8), gpx)
    }

    func testCopiedFileDataIsFound() {
        // A file copied in Files arrives as data under the file's own type,
        // with no string at all.
        let board = pasteboard()
        board.setData(Data(gpx.utf8), forPasteboardType: "com.topografix.gpx")
        guard case .track(_, let format) = ClipboardImportSheet.read(board) else {
            return XCTFail("GPX file data on the clipboard was not recognised")
        }
        XCTAssertEqual(format, .gpx)
    }

    func testArchiveTextIsFound() {
        let board = pasteboard()
        board.string = #"{"formatVersion":1,"generator":"openWater","session":{}}"#
        guard case .track(_, let format) = ClipboardImportSheet.read(board) else {
            return XCTFail("archive JSON on the clipboard was not recognised")
        }
        XCTAssertEqual(format, .openwater)
    }

    func testOtherTextIsSaidToBeText() {
        let board = pasteboard()
        board.string = "see you at the beach at 7"
        XCTAssertEqual(ClipboardImportSheet.read(board), .unrecognised(kind: "text"))
    }

    func testAnImageIsSaidToBeAnImage() {
        let board = pasteboard()
        board.image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        XCTAssertEqual(ClipboardImportSheet.read(board), .unrecognised(kind: "an image"))
    }
}
