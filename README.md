# Begleiter

**A private on-device journal for parents during pediatric leukemia treatment.** Submission to the [Gemma 4 Good Hackathon](https://www.kaggle.com/competitions/gemma-4-good-hackathon), Health track.

> In a long leukemia protocol, doctors can rotate. Parents are often the continuity layer. Begleiter helps them carry that story without sending it to a server.

## Demo Status

- **Final submission writeup:** `docs/FINAL_SUBMISSION.md`
- **Concise engineering writeup:** `docs/WRITEUP.md`
- **Demo video:** not uploaded yet; updated script in `docs/DEMO_VIDEO.md`
- **Demo data:** Settings -> Entwicklung -> **Demo-Daten laden** creates a synthetic child, chronological journal entries, and lab values. It refuses to overwrite real data.

## What It Does

Begleiter is a native iOS app for parents of children in AIEOP-BFM-style ALL treatment. It runs Gemma 4 E2B 4-bit on the iPhone via MLX-Swift, stores the journal locally with SwiftData, and keeps inference on-device.

Core workflows:

- **Capture:** type or dictate a visit note. Lab-report photos/PDFs are processed with local OCR, then Gemma 4 extracts structured fields such as medications, lab values, decisions, parent observations, and open questions.
- **Briefing:** generate a night-before appointment summary from the running journal.
- **Handoff:** produce a concise clinical-style catch-up summary for a newly rotating doctor.
- **Ask:** ask German questions grounded in the journal and bundled reference corpus. The submitted path uses the working custom Gemma 4 agent.
- **Plots:** turn structured lab history into trend views and natural-language plot requests.

Begleiter is not a clinical decision system. It does not diagnose, recommend medication changes, interpret emergency rules, or replace the care team.

## Stable Submission Scope

| Area | What is submitted | Code path |
|---|---|---|
| On-device Gemma 4 | E2B 4-bit text inference through MLX-Swift; no server inference | `Begleiter/Services/GemmaService.swift` |
| Structured extraction | Parent text + OCR text -> JSON fields in SwiftData | `Begleiter/Services/ExtractionService.swift` |
| Grounded Ask agent | Gemma 4 chooses read-only tools, then answers in German | `Begleiter/Services/AskService.swift`, `Begleiter/Services/GemmaToolCallExtractor.swift`, `Begleiter/Services/AgentTools.swift` |
| Thinking mode | Enabled for the custom agent path | `GemmaService.generate(enableThinking:)` |
| Citation warnings | Fabricated citation IDs are dropped; unsupported/advice-shaped claims surface warnings | `AskService.filterAndWarn` |
| Lab plots | Structured lab values become trends and plot requests | `Begleiter/Features/Labs/` |
| Visit reports | Pre-visit briefings and doctor handoff summaries | `Begleiter/Services/BriefingService.swift`, `Begleiter/Services/HandoffService.swift` |

The final submission focuses on the stable surface above.

## Why Gemma 4

Gemma 4 is used where language is messy:

- extracting structure from parent notes and OCR text
- generating concise German briefings and handoffs
- choosing retrieval tools in the Ask agent
- producing grounded German answers with citations

The protocol itself is not prompt magic. Treatment phases and metadata live in auditable Swift code under `Begleiter/Protocol/`.

## Privacy

- No telemetry, analytics, cloud sync, or server inference path.
- The clinical corpus is bundled in `Begleiter/Resources/corpus.json`.
- The only network dependency is the first-launch model download from Hugging Face.
- After the model is cached, the app can work in airplane mode.

## Quickstart

**Requirements**

- macOS with Xcode 26+
- iPhone with Increased Memory Limit support, such as iPhone 14 Pro or newer
- Free Apple Developer account for device signing

**Build and run**

```sh
git clone https://github.com/simonsays095/kaggle_gemma4-new-ai-features
cd kaggle_gemma4-new-ai-features
open Begleiter.xcodeproj
```

1. Plug in the iPhone and select it as the run destination.
2. In Signing & Capabilities, confirm **Increased Memory Limit** is present through `Begleiter/Begleiter.entitlements`.
3. Run the app. First launch downloads `mlx-community/gemma-4-e2b-it-4bit` into the on-device Hugging Face cache.
4. Open Settings -> Diagnose. The memory limit should report the increased per-app ceiling, not the default low ceiling.

## Tests

```sh
xcodebuild test \
  -project Begleiter.xcodeproj \
  -scheme Begleiter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Tests cover the protocol state machine, retrieval, tool dispatch, custom Gemma 4 tool-call parsing, extraction JSON parsing, lab plot resolution, and citation filtering. MLX inference itself requires a real iPhone because the simulator does not provide the needed Metal path.

## Repository Layout

```text
Begleiter/
├── App/                 # @main entry, RootView, memory-warning observer
├── Common/              # Runtime settings and feature toggles
├── Protocol/            # Deterministic AIEOP-BFM-style phase metadata
├── Models/              # SwiftData models
├── Features/            # SwiftUI surfaces: Timeline, Capture, Ask, Labs, Settings
├── Services/            # Gemma, extraction, retrieval, tools, reports, diagnostics
└── Resources/           # Localization and bundled reference corpus

BegleiterTests/          # XCTest coverage for non-MLX logic
docs/
├── FINAL_SUBMISSION.md  # Copy-ready final writeup
├── WRITEUP.md           # Concise stable engineering writeup
├── DEMO_VIDEO.md        # Stable demo script
└── upstream-issue-gemma4-toolcall.md
```

## License

Source code: MIT. The clinical corpus retains its source licenses; see the per-document headers inside `Begleiter/Resources/corpus.json`.
