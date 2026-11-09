import XCTest
@testable import TerminalMacCore

final class UnicodeTextTests: XCTestCase {
    func testNewlineIsIsolatedAtEveryChunkOffset() {
        for offset in 0...32 {
            let prefix = String(repeating: "a", count: offset)
            let text = prefix + "\nTARGET"
            let chunks = UnicodeText.chunks(text)
            XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
            XCTAssertEqual(chunks.filter { $0.contains(10) }, [[10]], "offset \(offset)")
            XCTAssertEqual(chunks.last, Array("TARGET".utf16), "offset \(offset)")
        }
    }

    func testLineBreaksAndTabsAreSeparateEvents() {
        for separator in ["\n", "\r", "\r\n", "\t", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let text = "before" + separator + "after"
            XCTAssertEqual(UnicodeText.chunks(text), [Array("before".utf16), Array(separator.utf16), Array("after".utf16)])
        }
        XCTAssertEqual(UnicodeText.chunks("\n\nTARGET\n"), [[10], [10], Array("TARGET".utf16), [10]])
    }

    func testPlainTextKeepsExistingChunkBoundaries() {
        XCTAssertEqual(UnicodeText.chunks(""), [])
        XCTAssertEqual(UnicodeText.chunks("0123456789abcdefTARGET"), [Array("0123456789abcdef".utf16), Array("TARGET".utf16)])
    }

    func testUnicodeCharactersRemainIntactAcrossBoundaries() {
        for character in ["🙂", "e\u{0301}", "👨‍👩‍👧‍👦", "e" + String(repeating: "\u{0301}", count: 40)] {
            let prefix = String(repeating: "x", count: 15)
            let text = prefix + character + "\n你好"
            let chunks = UnicodeText.chunks(text)
            XCTAssertEqual(chunks, [Array(prefix.utf16), Array(character.utf16), [10], Array("你好".utf16)])
            XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
        }
    }
}
