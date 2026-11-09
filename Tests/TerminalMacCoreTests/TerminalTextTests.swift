import XCTest
import TerminalUI

final class TerminalTextTests: XCTestCase {
    func testUntrustedControlsCannotReachTerminal() {
        let payload = "error \u{1b}[2J\u{1b}]52;c;AAAA\u{7}\u{9b}31m\r\n\t\u{7f}"
        let rendered = [Span(payload)].rendered
        XCTAssertFalse(rendered.unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) })
        XCTAssertTrue(rendered.contains("error"))
    }
    func testUnicodeAndTrustedStylesArePreserved() {
        let text = "中文 café 🐈"
        XCTAssertEqual([Span(text)].rendered, text)
        XCTAssertEqual([Span(text, "\u{1b}[31m")].rendered, "\u{1b}[31m" + text + Theme.reset)
        XCTAssertEqual([Span("a\u{1b}b")].truncated(2).rendered, "a…")
    }
}
