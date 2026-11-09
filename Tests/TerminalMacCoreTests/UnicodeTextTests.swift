import XCTest
@testable import TerminalMacCore

final class UnicodeTextTests: XCTestCase {
    func testLeadingNewlineHasNoTrailingPayloadAtEveryChunkOffset() {
        for offset in 0...32 {
            let text = String(repeating: "a", count: offset) + "\nTARGET"
            let chunks = UnicodeText.chunks(text)
            XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16), "offset \(offset)")
            for chunk in chunks where chunk.first == 10 {
                XCTAssertEqual(chunk, [10], "offset \(offset)")
            }
        }
    }

    func testLeadingLineBreaksAreSeparateEvents() {
        for separator in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(UnicodeText.chunks(separator + "after"), [Array(separator.utf16), Array("after".utf16)])
            let text = "before" + separator + "after"
            XCTAssertEqual(UnicodeText.chunks(text), [Array(text.utf16)])
        }
        XCTAssertEqual(UnicodeText.chunks("\n\nTARGET\n"), [[10], [10], Array("TARGET\n".utf16)])
    }

    func testEmbeddedTabsKeepExistingChunks() {
        for text in ["before\tafter", "a\t\tb", "a\t", "a\n\tb", "a\r\n\tb"] {
            XCTAssertEqual(UnicodeText.chunks(text), [Array(text.utf16)])
        }
        XCTAssertEqual(UnicodeText.chunks("0123456789abcde\tTARGET"),
                       [Array("0123456789abcde\t".utf16), Array("TARGET".utf16)])
    }

    func testTabIndentedLinesKeepExistingChunks() {
        let text = "header\n\tfirst\n\t\tsecond\nend"
        XCTAssertEqual(UnicodeText.chunks(text),
                       [Array("header\n\tfirst\n\t\t".utf16), Array("second\nend".utf16)])
    }

    func testWhitespaceDoesNotStartBoundaryChunks() {
        for offset in 1...32 {
            for separator in ["\t", "\n\t", "\r\n\t\t", "\n\n\t"] {
                let text = String(repeating: "a", count: offset) + separator + "TARGET"
                let chunks = UnicodeText.chunks(text)
                XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
                for chunk in chunks {
                    XCTAssertLessThanOrEqual(chunk.count, 16)
                    XCTAssertFalse([9, 10, 13].contains(chunk[0]), "offset \(offset), \(separator.debugDescription)")
                }
            }
        }
    }

    func testPlainTextKeepsExistingChunkBoundaries() {
        XCTAssertEqual(UnicodeText.chunks(""), [])
        XCTAssertEqual(UnicodeText.chunks("0123456789abcdefTARGET"), [Array("0123456789abcdef".utf16), Array("TARGET".utf16)])
    }

    func testUnicodeCharactersRemainIntactAcrossBoundaries() {
        for character in ["🙂", "e\u{0301}", "👨‍👩‍👧‍👦"] {
            let prefix = String(repeating: "x", count: 15)
            let text = prefix + character + "\n你好"
            XCTAssertEqual(UnicodeText.chunks(text), [Array(prefix.utf16), Array((character + "\n你好").utf16)])
        }
        let longCharacter = "e" + String(repeating: "\u{0301}", count: 40)
        XCTAssertEqual(UnicodeText.chunks(longCharacter + "\n你好"), [Array(longCharacter.utf16), [10], Array("你好".utf16)])
    }
}
