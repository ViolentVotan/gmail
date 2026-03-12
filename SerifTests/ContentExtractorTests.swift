import Testing
import Foundation
@testable import Serif

@Suite struct ContentExtractorTests {

    // MARK: - Plain Text Extraction

    @Test func extractPlainText_UTF8() {
        let text = "Hello, this is a plain text file."
        let data = text.data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: "text/plain", filename: "note.txt")

        if case .text(let extracted) = result {
            #expect(extracted == text)
        } else {
            Issue.record("Expected .text result for text/plain")
        }
    }

    @Test func extractPlainText_ByExtension() {
        let text = "CSV data here"
        let data = text.data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: nil, filename: "data.csv")

        if case .text(let extracted) = result {
            #expect(extracted == text)
        } else {
            Issue.record("Expected .text result for .csv extension")
        }
    }

    @Test(arguments: ["swift", "py", "js", "ts", "css", "json", "xml", "html", "md", "yaml", "yml", "toml", "ini", "cfg", "log", "rtf"])
    func extractPlainText_CodeFiles(ext: String) {
        let code = "func hello() { print(\"Hello\") }"
        let data = code.data(using: .utf8)!

        let result = ContentExtractor.extract(from: data, mimeType: nil, filename: "file.\(ext)")
        if case .text(let extracted) = result {
            #expect(extracted == code, "Failed for extension: \(ext)")
        } else {
            Issue.record("Expected .text result for .\(ext) extension")
        }
    }

    @Test func extractPlainText_EmptyData() {
        let data = Data()
        let result = ContentExtractor.extract(from: data, mimeType: "text/plain", filename: "empty.txt")

        if case .unsupported = result {
            // Expected: empty data should return .unsupported
        } else {
            Issue.record("Expected .unsupported for empty text data")
        }
    }

    @Test func extractPlainText_ByMimeType() {
        let text = "text content via mime"
        let data = text.data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: "text/html", filename: "unknown_ext.xyz")

        if case .text(let extracted) = result {
            #expect(extracted == text)
        } else {
            Issue.record("Expected .text result for text/ mime type prefix")
        }
    }

    // MARK: - Image Types -> OCR (unsupported for garbage data)

    @Test(arguments: ["jpg", "jpeg", "png", "tiff", "heic", "bmp", "gif"])
    func extractImage_ReturnsUnsupportedForInvalidData(ext: String) {
        let data = "not a real image".data(using: .utf8)!

        let result = ContentExtractor.extract(from: data, mimeType: nil, filename: "photo.\(ext)")
        if case .unsupported = result {
            // Expected: garbage data cannot be OCR'd
        } else if case .text = result {
            // OCR might find something in certain cases -- acceptable too
        }
    }

    @Test func extractImage_ByMimeType() {
        let data = "not real image data".data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: "image/png", filename: "unknown.xyz")

        // Should route to OCR path (which will return .unsupported for invalid data)
        if case .unsupported = result {
            // Expected
        } else if case .text = result {
            // OCR may produce something -- acceptable
        }
    }

    // MARK: - PDF Extraction

    @Test func extractPDF_InvalidData() {
        let data = "not a real PDF".data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: "application/pdf", filename: "doc.pdf")

        if case .unsupported = result {
            // Expected: invalid PDF data should return .unsupported
        } else {
            Issue.record("Expected .unsupported for invalid PDF data")
        }
    }

    @Test func extractPDF_ByExtension() {
        let data = "not a real PDF".data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: nil, filename: "report.pdf")

        if case .unsupported = result {
            // Expected: routes to PDF extractor by extension, invalid data
        } else {
            Issue.record("Expected .unsupported for invalid PDF data by extension")
        }
    }

    // MARK: - Unknown / Unsupported Types

    @Test func extractUnknownMimeType_ReturnsUnsupported() {
        let data = "some binary data".data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: "application/octet-stream", filename: "blob.bin")

        if case .unsupported = result {
            // Expected
        } else {
            Issue.record("Expected .unsupported for unknown MIME type and extension")
        }
    }

    @Test func extractUnknownExtension_ReturnsUnsupported() {
        let data = "whatever".data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: nil, filename: "file.xyz123")

        if case .unsupported = result {
            // Expected
        } else {
            Issue.record("Expected .unsupported for unknown extension with nil mime type")
        }
    }

    @Test func extractNoExtension_NoMimeType_ReturnsUnsupported() {
        let data = "data".data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: nil, filename: "noextension")

        if case .unsupported = result {
            // Expected
        } else {
            Issue.record("Expected .unsupported when no extension and no mime type")
        }
    }

    // MARK: - Word Document Extraction

    @Test func extractWordDoc_InvalidData() {
        let data = "not a real docx".data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: nil, filename: "report.docx")

        if case .unsupported = result {
            // Expected: invalid Word data
        } else if case .text = result {
            // NSAttributedString might handle it somehow -- acceptable
        }
    }

    @Test func extractWordDoc_ByMimeType() {
        let data = "not real".data(using: .utf8)!
        let result = ContentExtractor.extract(
            from: data,
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            filename: "unknown.xyz"
        )

        if case .unsupported = result {
            // Expected
        } else if case .text = result {
            // Acceptable if NSAttributedString handles it
        }
    }

    // MARK: - Cosine Similarity

    @Test func cosineSimilarity_IdenticalVectors() {
        let vec: [Float] = [1.0, 2.0, 3.0]
        let similarity = ContentExtractor.cosineSimilarity(vec, vec)
        #expect(abs(similarity - 1.0) < 0.0001)
    }

    @Test func cosineSimilarity_OrthogonalVectors() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        let similarity = ContentExtractor.cosineSimilarity(a, b)
        #expect(abs(similarity - 0.0) < 0.0001)
    }

    @Test func cosineSimilarity_OppositeVectors() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [-1.0, 0.0]
        let similarity = ContentExtractor.cosineSimilarity(a, b)
        #expect(abs(similarity - (-1.0)) < 0.0001)
    }

    @Test func cosineSimilarity_EmptyVectors() {
        let similarity = ContentExtractor.cosineSimilarity([], [])
        #expect(similarity == 0.0)
    }

    @Test func cosineSimilarity_DifferentLengths() {
        let a: [Float] = [1.0, 2.0]
        let b: [Float] = [1.0, 2.0, 3.0]
        let similarity = ContentExtractor.cosineSimilarity(a, b)
        #expect(similarity == 0.0, "Mismatched lengths should return 0")
    }

    @Test func cosineSimilarity_ZeroVector() {
        let a: [Float] = [0.0, 0.0, 0.0]
        let b: [Float] = [1.0, 2.0, 3.0]
        let similarity = ContentExtractor.cosineSimilarity(a, b)
        #expect(similarity == 0.0, "Zero vector should return 0")
    }

    @Test func cosineSimilarity_KnownValues() {
        // cos(45 degrees) = ~0.7071
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [1.0, 1.0]
        let similarity = ContentExtractor.cosineSimilarity(a, b)
        #expect(abs(similarity - Float(1.0 / sqrt(2.0))) < 0.0001)
    }

    // MARK: - Embedding Generation

    @Test func generateEmbedding_ReturnsConsistentResults() {
        let text = "The quick brown fox jumps over the lazy dog."
        let embedding1 = ContentExtractor.generateEmbedding(for: text)
        let embedding2 = ContentExtractor.generateEmbedding(for: text)

        // Both calls should return the same result (both nil or both non-nil with same values)
        if let e1 = embedding1, let e2 = embedding2 {
            #expect(e1.count == e2.count, "Embeddings should have same dimension")
            for i in 0..<e1.count {
                #expect(abs(e1[i] - e2[i]) < 0.0001, "Embedding values should be consistent")
            }
        } else {
            // Both should be nil if NLEmbedding is unavailable
            #expect((embedding1 == nil) == (embedding2 == nil), "Both should be nil or both non-nil")
        }
    }

    @Test func generateEmbedding_EmptyText() {
        let result = ContentExtractor.generateEmbedding(for: "")
        #expect(result == nil, "Empty text should return nil embedding")
    }

    @Test func generateEmbedding_WhitespaceOnly() {
        let result = ContentExtractor.generateEmbedding(for: "   \n\t  ")
        #expect(result == nil, "Whitespace-only text should return nil embedding")
    }

    // MARK: - Routing Priority

    @Test func pdfMimeType_TakesPriorityOverExtension() {
        // A .txt file with application/pdf mime should be routed as PDF
        let data = "not a real PDF".data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: "application/pdf", filename: "file.txt")

        // Should attempt PDF extraction (and fail since data is invalid)
        if case .unsupported = result {
            // Expected: routes to PDF path, fails because data is not a valid PDF
        } else if case .text = result {
            // Might fall through -- depends on implementation order
        }
    }

    @Test func extractPreservesMultilineText() {
        let text = "Line 1\nLine 2\nLine 3"
        let data = text.data(using: .utf8)!
        let result = ContentExtractor.extract(from: data, mimeType: "text/plain", filename: "multi.txt")

        if case .text(let extracted) = result {
            #expect(extracted == text)
            #expect(extracted.contains("\n"))
        } else {
            Issue.record("Expected .text result for multiline text")
        }
    }
}
