import Foundation

enum ModelJSON {
    /// Accept a complete JSON code block as well as a bare JSON response.
    static func data(_ text: String) -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        if let first = lines.first, ["```json", "```"].contains(first.lowercased()),
           lines.count >= 3, lines.last == "```" {
            return Data(lines.dropFirst().dropLast().joined(separator: "\n").utf8)
        }
        return Data(trimmed.utf8)
    }
}
