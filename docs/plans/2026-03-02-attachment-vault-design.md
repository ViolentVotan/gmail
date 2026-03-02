# Attachment Vault — Design Document

## Overview

Transform the Attachments sidebar category into a full-featured attachment explorer with content-based search. Attachments are never stored locally — only their extracted text, metadata, and semantic embeddings are persisted in a local SQLite database. Gmail's API provides on-demand re-download via `attachmentId`.

## Architecture: SQLite Monolithic (Approach A)

Single SQLite file with FTS5 full-text search + NaturalLanguage.framework embeddings for hybrid keyword/semantic search. Zero external dependencies.

## Data Layer

**Database location:** `~/Library/Application Support/com.serif.app/attachment-index.sqlite`

### Schema

```sql
CREATE TABLE attachments (
    id              TEXT PRIMARY KEY,    -- "{messageId}_{attachmentId}"
    messageId       TEXT NOT NULL,
    attachmentId    TEXT NOT NULL,       -- Gmail attachment ID for re-download
    filename        TEXT NOT NULL,
    mimeType        TEXT,
    fileType        TEXT,               -- pdf, image, document, spreadsheet, archive, presentation, code
    size            INTEGER,
    senderEmail     TEXT,
    senderName      TEXT,
    emailSubject    TEXT,
    emailDate       REAL,               -- Unix timestamp
    direction       TEXT,               -- "received" / "sent"
    indexedAt       REAL,               -- when content was indexed
    indexingStatus  TEXT,               -- "pending" / "indexed" / "failed" / "unsupported"
    embedding       BLOB                -- NaturalLanguage vector (serialized Float array)
);

CREATE VIRTUAL TABLE attachments_fts USING fts5 (
    content,                            -- extracted text
    filename,                           -- searchable filename
    emailSubject,                       -- searchable email subject
    content=attachments,
    content_rowid=rowid
);
```

## Indexation Pipeline — AttachmentIndexer (Swift Actor)

### Flow

```
Email fetched → new attachments detected
    ↓
AttachmentIndexer.index(attachments:)
    ↓
For each unindexed attachment:
    1. INSERT metadata into SQLite (status = "pending")
    2. Download via GmailMessageService.getAttachment() → temp file
    3. Extract text:
       - PDF  → PDFKit (PDFDocument.string)
       - Images (jpg/png/tiff/heic) → Vision (VNRecognizeTextRequest OCR)
       - Text/CSV/JSON/XML → direct UTF-8 read
       - Others → "unsupported", index filename only
    4. INSERT text into FTS5
    5. Generate embedding: NLEmbedding sentence/word embedding → average vector
    6. UPDATE status = "indexed", store embedding as BLOB
    7. Delete temp file
```

### Throttling

- Max 3 concurrent downloads (avoid Gmail rate limits)
- FIFO queue, prioritize recent attachments
- Retry failed indexing on next app launch

## Search Engine — AttachmentSearchService

### Hybrid Search Strategy

```
User types "facture EDF"
    ↓
1. FTS5: SELECT with BM25 ranking → exact keyword matches (instant)
2. If < 5 results → Semantic fallback:
   - Generate query embedding via NLEmbedding
   - Load all embeddings from SQLite
   - Cosine similarity → top results
3. Merge + deduplicate + sort by combined score
4. Return [AttachmentSearchResult] with relevance score
```

## UI — AttachmentExplorerView

### Layout

When `selectedFolder == .attachments`:
- ListPane + DetailPane are hidden
- AttachmentExplorerView takes full remaining width (after sidebar)

### Components

- **Search bar** at top with 300ms debounce
- **Filter chips**: file type (PDF, Image, Doc, etc.), direction (received/sent), date range
- **Grid of cards**: icon by type, filename, sender name, date, relevance score (during search)
- **Click card** → preview sheet (reuses AttachmentPreviewView, re-downloads from Gmail)
- **Empty/indexing state**: progress indicator with count of indexed/total attachments

## Integration Points

1. **MailboxViewModel.loadFolder()**: after each email fetch, send new attachments to AttachmentIndexer
2. **ContentView**: when `selectedFolder == .attachments`, swap ListPane+DetailPane for AttachmentExplorerView
3. **New model**: `IndexedAttachment` for the database (separate from existing `Attachment` model)
4. **AttachmentStore**: ObservableObject exposing search results and indexing stats to UI
5. **No changes** to existing Email/Attachment/MailStore models

## New Files

- `Serif/Services/AttachmentDatabase.swift` — SQLite wrapper (CRUD + FTS5 + embeddings)
- `Serif/Services/AttachmentIndexer.swift` — Background actor for download/extract/index
- `Serif/Services/AttachmentSearchService.swift` — Hybrid search logic
- `Serif/Services/ContentExtractor.swift` — PDF/OCR/text extraction
- `Serif/Models/IndexedAttachment.swift` — DB model + search result model
- `Serif/ViewModels/AttachmentStore.swift` — ObservableObject for UI
- `Serif/Views/Attachments/AttachmentExplorerView.swift` — Main grid view
- `Serif/Views/Attachments/AttachmentCardView.swift` — Single card in grid
