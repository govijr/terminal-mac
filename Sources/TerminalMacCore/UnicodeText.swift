/// UTF-16 payloads for literal keyboard events, keeping each Character intact.
public enum UnicodeText {
    public static func chunks(_ text: String) -> [[UInt16]] {
        var result: [[UInt16]] = []
        var chunk: [UInt16] = []
        var lastTextStart: Int?
        func flush() {
            guard !chunk.isEmpty else { return }
            result.append(chunk)
            chunk.removeAll(keepingCapacity: true)
            lastTextStart = nil
        }
        for character in text {
            let units = Array(String(character).utf16)
            let separator = character.isNewline || character == "\t"
            if chunk.count + units.count > 16 {
                // Keep a separator from starting the next event by carrying the
                // preceding text Character with it, within the existing budget.
                if separator, let start = lastTextStart, start > 0,
                   chunk.count - start + units.count <= 16 {
                    result.append(Array(chunk[..<start]))
                    chunk = Array(chunk[start...])
                    lastTextStart = 0
                } else { flush() }
            }
            // A leading line break can consume the rest of an event's payload.
            // Keep embedded whitespace with its existing text chunk.
            if chunk.isEmpty && character.isNewline {
                result.append(units)
                continue
            }
            if !separator { lastTextStart = chunk.count }
            chunk += units
        }
        flush()
        return result
    }
}
