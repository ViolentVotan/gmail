import Foundation
import GRDB
@testable import Serif

enum TestHelpers {
    static func makeTestDatabase() throws -> (db: MailDatabase, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let db = try MailDatabase(accountID: "test", baseDirectory: tempDir)
        return (db: db, tempDir: tempDir)
    }
}
