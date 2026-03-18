internal import os

extension Logger {
    /// Convenience initializer using the app's bundle identifier as subsystem.
    init(category: String) {
        self.init(subsystem: "com.vikingz.vik", category: category)
    }
}
