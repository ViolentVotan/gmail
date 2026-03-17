import Foundation
import AppKit
import PDFKit
private import Vision
private import NaturalLanguage

// MARK: - Content Extractor

/// Utility for extracting searchable text from attachment data and generating embeddings.
/// Used by AttachmentIndexer to populate FTS5 and embedding columns.
enum ContentExtractor {

    // MARK: - Extraction Result

    enum ExtractionResult {
        case text(String)
        case unsupported
    }

    // MARK: - Supported Extensions

    private static let imageExtensions: Set<String> = FileUtils.imageExtensions

    private static let textExtensions: Set<String> = [
        "txt", "csv", "json", "xml", "html", "md", "rtf", "log",
        "swift", "py", "js", "ts", "css", "yaml", "yml", "toml", "ini", "cfg"
    ]

    private static let wordMimeTypes: Set<String> = [
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/msword",
        "application/vnd.oasis.opendocument.text"
    ]

    private static let wordExtensions: Set<String> = ["doc", "docx", "odt"]

    // MARK: - Public API

    /// Route extraction based on file extension and MIME type.
    @concurrent
    static func extract(from data: Data, mimeType: String?, filename: String) async -> ExtractionResult {
        let ext = (filename as NSString).pathExtension.lowercased()

        // PDF
        if ext == "pdf" || mimeType == "application/pdf" {
            return await extractPDF(data: data)
        }

        // Word documents (.doc, .docx, .odt)
        if wordExtensions.contains(ext) || wordMimeTypes.contains(mimeType ?? "") {
            return extractWordDocument(data: data, ext: ext.isEmpty ? "docx" : ext)
        }

        // Images
        if imageExtensions.contains(ext) || (mimeType?.hasPrefix("image/") == true) {
            return await extractOCR(data: data)
        }

        // Plain-text family
        if textExtensions.contains(ext) || mimeType?.hasPrefix("text/") == true {
            return extractText(data: data)
        }

        return .unsupported
    }

    // MARK: - PDF

    private static func extractPDF(data: Data) async -> ExtractionResult {
        if #available(macOS 26.0, *) {
            let result = await extractPDFWithDocumentRecognition(data: data)
            if case .text = result { return result }
        }
        return extractPDFWithLegacy(data: data)
    }

    @available(macOS 26.0, *)
    private static func extractPDFWithDocumentRecognition(data: Data) async -> ExtractionResult {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            return .unsupported
        }

        var allText: [String] = []

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let pageImage = page.thumbnail(of: CGSize(width: 2048, height: 2048), for: .mediaBox)
            guard let tiffData = pageImage.tiffRepresentation else { continue }

            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.recognitionLanguages = [
                Locale.Language(identifier: "fr-FR"),
                Locale.Language(identifier: "en-US")
            ]
            request.textRecognitionOptions.useLanguageCorrection = true

            guard let observations = try? await request.perform(on: tiffData),
                  !observations.isEmpty else {
                continue
            }

            let pageText = observations.map { observation in
                extractText(from: observation.document)
            }
            .joined(separator: "\n\n")

            if !pageText.isEmpty {
                allText.append(pageText)
            }
        }

        let combined = allText.joined(separator: "\n\n")
        return combined.isEmpty ? .unsupported : .text(combined)
    }

    private static func extractPDFWithLegacy(data: Data) -> ExtractionResult {
        guard let document = PDFDocument(data: data) else { return .unsupported }

        var pages: [String] = []
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let text = page.string, !text.isEmpty {
                pages.append(text)
            }
        }

        let combined = pages.joined(separator: "\n")
        return combined.isEmpty ? .unsupported : .text(combined)
    }

    // MARK: - OCR (Vision)

    private static func extractOCR(data: Data) async -> ExtractionResult {
        if #available(macOS 26.0, *) {
            return await extractWithDocumentRecognition(data: data)
        }
        return extractWithLegacyOCR(data: data)
    }

    @available(macOS 26.0, *)
    private static func extractWithDocumentRecognition(data: Data) async -> ExtractionResult {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = [
            Locale.Language(identifier: "fr-FR"),
            Locale.Language(identifier: "en-US")
        ]
        request.textRecognitionOptions.useLanguageCorrection = true

        do {
            let observations = try await request.perform(on: data)

            guard !observations.isEmpty else {
                return extractWithLegacyOCR(data: data)
            }

            let text = observations.map { observation in
                extractText(from: observation.document)
            }
            .joined(separator: "\n\n")

            return text.isEmpty ? extractWithLegacyOCR(data: data) : .text(text)
        } catch {
            return extractWithLegacyOCR(data: data)
        }
    }

    @available(macOS 26.0, *)
    private static func extractText(from container: DocumentObservation.Container) -> String {
        var sections: [String] = []

        // Extract paragraph text
        for paragraph in container.paragraphs {
            let transcript = paragraph.transcript
            if !transcript.isEmpty {
                sections.append(transcript)
            }
        }

        // Extract table content as formatted text
        for table in container.tables {
            var tableLines: [String] = []
            for row in table.rows {
                let cells = row.map { cell in
                    extractText(from: cell.content)
                }
                tableLines.append(cells.joined(separator: " | "))
            }
            if !tableLines.isEmpty {
                sections.append(tableLines.joined(separator: "\n"))
            }
        }

        // Extract list items
        for list in container.lists {
            let items = list.items.map { item in
                "\(item.markerString) \(item.itemString)"
            }
            if !items.isEmpty {
                sections.append(items.joined(separator: "\n"))
            }
        }

        // Fallback to the full text transcript if no structured content was found
        if sections.isEmpty {
            let transcript = container.text.transcript
            if !transcript.isEmpty {
                sections.append(transcript)
            }
        }

        return sections.joined(separator: "\n\n")
    }

    private static func extractWithLegacyOCR(data: Data) -> ExtractionResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(data: data, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .unsupported
        }

        guard let observations = request.results, !observations.isEmpty else {
            return .unsupported
        }

        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")

        return text.isEmpty ? .unsupported : .text(text)
    }

    // MARK: - Word Documents

    private static func extractWordDocument(data: Data, ext: String) -> ExtractionResult {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try data.write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }
            let attributed = try NSAttributedString(url: tempFile, options: [:], documentAttributes: nil)
            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .unsupported : .text(text)
        } catch {
            return .unsupported
        }
    }

    // MARK: - Plain Text

    private static func extractText(data: Data) -> ExtractionResult {
        guard let string = String(data: data, encoding: .utf8), !string.isEmpty else {
            return .unsupported
        }
        return .text(string)
    }

    // MARK: - Embedding Generation

    /// Generate an averaged sentence embedding using NaturalLanguage.framework.
    /// Splits the input into sentences, embeds each (capped at 100), and averages the vectors.
    static func generateEmbedding(for text: String) -> [Float]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return sentences.count < 100
        }

        guard !sentences.isEmpty else { return nil }

        let dimension = embedding.dimension
        var sum = [Double](repeating: 0.0, count: dimension)
        var count = 0

        for sentence in sentences {
            if let vector = embedding.vector(for: sentence) {
                for i in 0..<dimension {
                    sum[i] += vector[i]
                }
                count += 1
            }
        }

        guard count > 0 else { return nil }

        let scale = 1.0 / Double(count)
        return sum.map { Float($0 * scale) }
    }

    // MARK: - Cosine Similarity

    /// Compute cosine similarity between two vectors of equal length.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrtf(normA) * sqrtf(normB)
        guard denominator > 0 else { return 0 }

        return dot / denominator
    }
}
