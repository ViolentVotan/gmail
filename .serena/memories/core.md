# Core — Vik

Native macOS Gmail client (Swift 6.2 / SwiftUI / macOS 26+) with multi-account Gmail, Google Calendar integration, tracker blocking, optimistic UI, Apple Intelligence, and offline queues — built on GRDB SQLite and Google's REST APIs.

## Project Identity & Setup

- `mem:project_overview` — target platform (macOS 26+, Xcode 26.3), bundle ID, key features (delta sync, Calendar, tracker blocking, CI/CD pipeline, build/test commands). Read first when onboarding or setting up the environment.

## Architecture & File Layout

- `mem:codebase_structure` — full directory tree (Vik/, VikTests/, docs/, scripts/), MVVM coordinator hierarchy (AppCoordinator + 7 sub-coordinators), complete service catalog (~50 services), SPM dependencies (AppAuth-iOS 1.7.6, GRDB.swift 7.10.0), and data-flow invariant (Services → ViewModels → Views). Read before navigating unfamiliar modules or adding new services/VMs.

## Code Conventions

- `mem:code_style` — Swift 6.2 style (formatting, naming, access control), MVVM contracts (`@Observable @MainActor final class` VMs, value-type models, pure Views), concurrency rules (`@MainActor`/`@concurrent` split, typed throws, structured concurrency), SwiftUI patterns (`@State`/`@Bindable`, theming via DesignTokens/AppearanceManager), GRDB record patterns (10 record types, snake_case column strategy, WAL config, FTS5 setup, actor-scoped bulk writes), and testing conventions (Swift Testing only — `@Test`/`#expect`, no XCTest). Read before writing or reviewing any Swift code.

## Developer Workflow

- `mem:suggested_commands` — xcodebuild commands for build, test, clean, and release (tag-push CI vs. manual `release.sh`). Read when running builds, tests, or preparing a release.
