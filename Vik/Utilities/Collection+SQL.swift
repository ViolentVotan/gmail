import Foundation

extension Collection {
    /// Generates SQL placeholders for parameterized queries (e.g., "?,?,?")
    var sqlPlaceholders: String {
        map { _ in "?" }.joined(separator: ",")
    }
}
