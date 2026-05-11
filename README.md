# Begleiter

iOS-native multimodal medical journal for parents of children in AIEOP-BFM ALL 2017 treatment. Submitted to the **Gemma 4 Good Hackathon** (Kaggle, hosted by Google DeepMind). Deadline: **2026-05-18**.

> Working name "Begleiter" (German for *companion*). See `Project.md` for the full product spec.

## Status

| Iteration | Scope | Status |
|---|---|---|
| 1 | Protocol state machine + onboarding flow | ✅ scaffolded (this commit) |
| 2 | Xcode project + MLX-Swift + Gemma 4 E4B loading | ⏳ next |
| 3 | Text-only journal + GemmaService function calling | ⏳ |
| 4+ | Voice (WhisperKit), photos (Vision OCR), retrieval, briefing, handoff | ⏳ |

Iteration 1 is intentionally code-only (no `.xcodeproj`) so a clinical advisor can review `Begleiter/Protocol/PhaseMetadata.swift` and `Begleiter/Protocol/PhaseTransitions.swift` before any AI behavior is wired up.

## Repository layout

```
Begleiter/
├── App/                        # @main entry + RootView + HomePlaceholder
├── Protocol/                   # Deterministic BFM 2017 state machine
├── Models/                     # SwiftData @Model types (ChildState)
├── Features/Onboarding/        # 4-screen onboarding flow
├── Common/                     # Shared utilities (L10n)
└── Resources/                  # de.lproj + en.lproj Localizable.strings

BegleiterTests/                 # XCTest unit tests for state machine + model
Project.md                      # Full product specification
```

## First-time setup (creating the Xcode project)

The scaffolded source files are designed to drop into a fresh Xcode project. The first developer to open this repo on a Mac should:

1. Open Xcode (15+ recommended) → **File → New → Project…**
2. Choose **iOS → App**. Settings:
   - Product name: `Begleiter`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **SwiftData**
   - Tick **Include Tests**
   - Minimum iOS: **17.0**
3. Save the project at `kaggle_gemma4/Begleiter.xcodeproj` (parallel to the `Begleiter/` source directory, not inside it).
4. In the file navigator, **delete** the placeholder files Xcode creates (`BegleiterApp.swift`, `ContentView.swift`, the default `Item` model, and the default test file) — they will be replaced by the scaffolded files.
5. Right-click the project root → **Add Files to "Begleiter"…** Select the entire `Begleiter/` directory. Tick **Create groups** (not folder references). Make sure the app target is selected.
6. Same for `BegleiterTests/` — add it to the `BegleiterTests` test target.
7. Build settings:
   - Deployment target: **iOS 17.0**
   - Localization: add **German** (de) under **Project → Info → Localizations**.
8. Build and run on the iOS Simulator (or a device). Cold launch should show the German onboarding flow.

## Adding the ML packages (iteration 2, not yet wired up)

When iteration 2 begins, add via **File → Add Package Dependencies…**:

- `https://github.com/ml-explore/mlx-swift`
- `https://github.com/argmaxinc/WhisperKit`

Neither is required for iteration 1 to build or run.

## Running tests

After Xcode setup:

```sh
xcodebuild test \
  -project Begleiter.xcodeproj \
  -scheme Begleiter \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

All four test files under `BegleiterTests/` are pure Swift and require no fixtures.

## Clinical review pass

Every clinical claim in the protocol module is marked `// CLINICAL-REVIEW:`. Find them with:

```sh
rg "CLINICAL-REVIEW" Begleiter/Protocol/
```

The two highest-value files for advisor review are:

- `Begleiter/Protocol/PhaseMetadata.swift` — drug schedules, durations, parent concerns per phase
- `Begleiter/Protocol/PhaseTransitions.swift` — legal transitions between phases

## License & data

- The BFM 2017 protocol PDF is **not licensable** and **not** in this repo.
- The corpus the AI grounds on is restricted to open-access AIEOP-BFM publications, kinderkrebsinfo.de parent education content, and EMA SmPCs.
- All processing is on-device. Nothing leaves the iPhone.
