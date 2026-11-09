/// UTF-16 payloads for literal keyboard events, keeping each Character intact.
public enum UnicodeText {
    public static func chunks(_ text: String) -> [[UInt16]] {
        var result: [[UInt16]] = []
        var chunk: [UInt16] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            result.append(chunk)
            chunk.removeAll(keepingCapacity: true)
        }
        for character in text {
            let units = Array(String(character).utf16)
            // Text systems can interpret a leading line break or tab as a command,
            // consuming the event without inserting the rest of its Unicode payload.
            if character.isNewline || character == "\t" {
                flush()
                result.append(units)
                continue
            }
            if chunk.count + units.count > 16 { flush() }
            chunk += units
        }
        flush()
        return result
    }
}
