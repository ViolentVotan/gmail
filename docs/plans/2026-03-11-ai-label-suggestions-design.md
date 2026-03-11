# AI Label Suggestions — Design

## Overview
Use Apple Intelligence (FoundationModels, macOS 26+) to suggest up to 3 relevant labels when viewing an email. Suggestions appear as clickable chips below the existing LabelEditorView in the detail pane.

## Behavior
- Triggered when an email is selected in the detail pane
- Sends subject + preview + existing Gmail user labels to FoundationModels
- Returns max 3 label suggestions (existing or new to create)
- Results cached per email (`gmailMessageID` as key)
- Clicking a chip adds the label (creates it first if new), then removes the chip
- Feature gated behind macOS 26+ availability and a user setting (default: enabled)

## UI
- Chips displayed directly below `LabelEditorView`, no section header
- Existing labels: chip with `+` icon
- New labels (to create): chip with `plus.circle` icon
- Subtle fade-in animation when suggestions load
- Chips disappear individually when tapped

## Prompt Strategy
Input: email subject, preview (120 chars), list of user label names.
Output: JSON array `[{"name": "Travel", "isNew": false}, ...]` — max 3 items.
`isNew` = true when the suggested name doesn't match any existing label.

## Settings
New "Apple Intelligence" card in Settings:
- Toggle: "Label suggestions" — `@AppStorage("aiLabelSuggestions")`, default `true`
- Card can host future AI feature toggles

## Files
| File | Change |
|------|--------|
| `Serif/Services/LabelSuggestionService.swift` | **New** — AI prompt, parsing, in-memory cache |
| `Serif/Views/EmailDetail/EmailDetailView.swift` | Add suggestion chips below LabelEditorView |
| `Serif/Views/EmailDetail/DetailPaneView.swift` | Pass labels + callbacks to EmailDetailView |
| `Serif/Views/Common/SettingsCardsView.swift` | New "Apple Intelligence" settings card |
