# Begleiter

iOS-native multimodal medical journal for parents of children in AIEOP-BFM ALL 2017 treatment. Submitted to the **Gemma 4 Good Hackathon** (Kaggle, hosted by Google DeepMind). Deadline: **2026-05-18**.

> Working name "Begleiter" (German for *companion*). See `Project.md` for the full product spec.

## Status

| Iteration | Scope | Status |
|---|---|---|
| 1 | Protocol state machine + onboarding flow | ✅ done |
| 2 | Xcode project + MLX-Swift + Gemma 4 E4B loading smoke test | 🟡 code scaffolded, packages to add (see below) |
| 3 | Text-only journal + GemmaService function calling | ⏳ |
| 4+ | Voice (WhisperKit), photos (Vision OCR), retrieval, briefing, handoff | ⏳ |

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

## Adding the ML packages (iteration 2)

Iteration 2 scaffolds `Services/GemmaService.swift` + `Features/Debug/SmokeTestView.swift`, which import MLX-Swift modules. Before the code compiles, add these packages via **File → Add Package Dependencies…** in Xcode:

| Repository URL | Required products (check boxes) | Add to target |
|---|---|---|
| `https://github.com/ml-explore/mlx-swift-examples` | `MLXLLM`, `MLXLMCommon` | Begleiter |
| `https://github.com/argmaxinc/WhisperKit` | `WhisperKit` | Begleiter (not yet imported — iteration 4) |

After each "Add Package", wait for SPM resolution, then tick only the listed products and confirm the target is `Begleiter` (NOT the test targets).

> Do **not** add `https://github.com/ml-explore/mlx-swift` as a separate top-level package. `mlx-swift-examples` already depends on it transitively at a pinned version; adding it directly causes an SPM version conflict (`mlx-swift-examples 2.29.x` requires `mlx-swift 0.29.x`, but Xcode auto-resolves the standalone entry to a newer minor).

### Running the smoke test

1. Add the three packages above. Build (Cmd+B) — should be green.
2. Plug in your iPhone 14 Pro. In Xcode, set the run destination to your device. Sign in to your Apple Developer account under **Xcode → Settings → Accounts**; let Xcode automatic-manage signing for the `Begleiter` target.
3. Run (Cmd+R). Walk through onboarding once if you haven't already.
4. From the home placeholder, tap **Entwicklung → Gemma 4 Smoke-Test**.
5. Tap **Modell laden**. On first launch the model (~2 GB) downloads from Hugging Face; the progress bar shows download fraction. Subsequent launches load from cache.
6. Tap **Antwort erzeugen** to run the default German prompt. A response should render within a few seconds.

If the load fails with a model-not-found error, update `GemmaService.Configuration.default.modelId` in `Begleiter/Services/GemmaService.swift` to point at the current `mlx-community` repo for Gemma 4 E4B. The placeholder defaults to `mlx-community/gemma-3-4b-it-4bit` — see the `TODO(iteration-2)` comment in that file.

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
