# Begleiter

**An offline iPhone memory layer that helps parents carry the treatment story when doctors rotate.** Submission to the [Gemma 4 Good Hackathon](https://www.kaggle.com/competitions/gemma-4-good-hackathon) (Kaggle, hosted by Google DeepMind, Health track).

> _"In a two-year leukemia protocol, the doctors rotate. Parents are the only constant. We give them the tools to carry that weight."_

## Demo

- **90-second walkthrough video:** _link pending upload_ (script + shot list in `docs/DEMO_VIDEO.md`)
- **Screenshots (for judges without a supported device):** `docs/screenshots/` — onboarding completion, populated home timeline, Ask flow with validated citations + warning chip, multimodal lab extraction, Settings → Diagnose proving the Increased Memory Limit entitlement is signed.
- **Try it without typing journal entries:** Settings → Entwicklung → **Demo-Daten laden** synthesizes a fully-extracted SR child + 10 chronological journal entries + 1 imported Entlassungsbericht. Refuses to overwrite real data; pair with the **Reset alle Daten** inverse if you want a clean state.

A native iOS app (Swift / SwiftUI) for parents of children in AIEOP-BFM ALL 2017 treatment. Runs entirely on the iPhone — no network, no telemetry, no cloud. Gemma 4 E2B 4-bit (~2 GB resident) handles every model call via MLX-Swift. The architectural principle: **hard-code the protocol, use Gemma 4 for the soft work.** When Gemma cites a journal entry or corpus chunk, a post-hoc filter validates the citation against the surfaced context — fabricated IDs are dropped, and any uncited or advice-shaped claim surfaces a visible warning so the parent always sees both the model's prose and the safety signal attached to it.

## What it does

- **Capture** — parent types, dictates, or photographs a journal entry. Gemma 4 extracts structured fields (drugs, lab values, decisions, parent observations, open questions) into a longitudinal SwiftData record.
- **Briefing** — generates the night-before-appointment summary from the running journal. Claims attributed to a journal entry carry an `[E:UUID]` marker; claims attributed to the deterministic protocol state machine carry none. Advice-shaped prose is scrubbed to the canonical redirect message.
- **Handoff** — produces a clinical-style one-page catch-up summary when a new rotating doctor takes over.
- **Ask** — German Q&A grounded in the journal + a curated clinical corpus. Three modes (Settings → Entwicklung → Antwort-Modus):
  1. **Chat** (default) — single-shot retrieve-then-prompt, BM25 + optional E5 dense rerank.
  2. **MLX-Werkzeug-Aufrufe** — `ChatSession(tools:)`. Currently broken upstream for Gemma 4 (`docs/upstream-issue-gemma4-toolcall.md`); kept for evidence.
  3. **Eigener Agent** — our own parser + multi-turn loop; dispatches 4 tools (`search_journal`, `search_corpus`, `get_lab_trend`, `get_phase_metadata`).

## Gemma 4 capabilities exercised

| Capability | Parent value | Proof in app | Code path |
|---|---|---|---|
| Native text inference (E2B 4-bit) | Every model call stays on the iPhone — no operator can see the journal | Capture / Briefing / Handoff / Ask all run through one shared actor | `Services/GemmaService.swift` |
| Native multimodal (image + text) | Lab-report photos go straight to the model — table columns and handwritten margin notes survive | Settings → Befund-Verarbeitung → "Direkt multimodal" | `Services/GemmaVisionService.swift`, `ExtractionService.extractWithVision` |
| Native function calling (custom loop) | The model picks read-only tools over the parent's journal — no chat memorisation | Settings → Entwicklung → Antwort-Modus → "Eigener Agent" | `Services/GemmaToolCallExtractor.swift`, `AskService.answerCustomAgent` |
| Thinking mode (`<\|channel\|>thought`) | Reasoning-before-tool-call for harder agent questions | Always on in agent mode; opt-in for single-shot Ask | `GemmaService.generate(enableThinking:)` |
| Long-context document memory (128 K) | Import a discharge letter / lab PDF; Gemma builds a cited document memory the agent can search alongside the journal | Settings → Entwicklung → "Dokument-Speicher" → "PDF importieren" | `Models/ImportedDocument.swift`, `Services/DocumentImportService.swift`, `AgentTools.searchDocuments` |

See `docs/WRITEUP.md` for the engineering deep-dive — why two factories, how the mutex works, how we walked the iPhone 14 Pro's memory ceiling, how we worked around the upstream tool-call gap.

## Quickstart

**Requirements**
- macOS with Xcode 26+
- iPhone with **Increased Memory Limit** support (14 Pro / 15 / 15 Pro / 16 Pro). E2B works on 6 GB devices; E4B needs 8 GB.
- Free Apple Developer account (for device signing).

**Build & run**

```sh
git clone https://github.com/simonsays095/kaggle_gemma4-new-ai-features
cd kaggle_gemma4-new-ai-features
open Begleiter.xcodeproj
```

1. Plug in your iPhone. In Xcode, select your device as the run destination.
2. Signing & Capabilities → confirm **Increased Memory Limit** is listed (already in `Begleiter.entitlements`).
3. Cmd+R. First launch downloads `mlx-community/gemma-4-e2b-it-4bit` (~2 GB) into the on-device Hugging Face cache. Subsequent launches load from cache.

**Verifying the model is honoured**

Open Settings → Diagnose. The **Speicher-Limit (App)** row should report ~3 GB (6 GB device) or ~4 GB (8 GB device). If it reports ~1.5 GB, the Increased Memory Limit entitlement isn't being signed in — clean build & reinstall.

## Tests

```sh
xcodebuild test \
  -project Begleiter.xcodeproj \
  -scheme Begleiter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Test surface covers the protocol state machine, the BM25 retriever, the tool dispatcher, the Gemma-4 tool-call parser, the extraction JSON parser, and the verifiable-generation citation filter. MLX inference itself can't run on Simulator (no Metal device); on-device extraction is exercised via the smoke test (Settings → Entwicklung → Gemma 4 Smoke-Test) and the Capture / Ask flows.

## Repository layout

```
Begleiter/
├── App/                        # @main entry + RootView + memory-warning observer
├── Common/AppSettings.swift    # All runtime toggles (model variant, ask mode, lab pipeline mode, …)
├── Protocol/                   # AIEOP-BFM 2017 deterministic state machine (Phase, PhaseMetadata, …)
├── Models/                     # SwiftData @Model types (JournalEntry, ChildState, ExtractedFields, LabPlotSpec, …)
├── Features/                   # SwiftUI views per surface
│   ├── Onboarding/             # 4-screen onboarding flow
│   ├── Timeline/               # Journal timeline + entry detail
│   ├── Capture/                # Text + voice + photo capture
│   ├── Briefing/               # Pre-visit briefing
│   ├── Handoff/                # Clinical catch-up handoff
│   ├── Ask/                    # German Q&A (three modes)
│   ├── LabValues/              # Per-parameter trend plots
│   ├── Settings/               # All toggles + Diagnose memory probe
│   └── Debug/                  # Smoke test, MemoryDiagnostics
├── Services/                   # All ML + retrieval
│   ├── GemmaService.swift      # Text-only Gemma 4 (MLXLLM)
│   ├── GemmaVisionService.swift# Multimodal Gemma 4 (MLXVLM); mutex with GemmaService
│   ├── ExtractionService.swift # Free-text / OCR / vision → ExtractedFields JSON
│   ├── AskService.swift        # Q&A pipeline + agent loops
│   ├── AgentTools.swift        # Tool registry + dispatchers
│   ├── GemmaToolCallExtractor.swift # Custom parser for Gemma 4's native call:fn{…} syntax
│   ├── RetrievalService.swift  # BM25 over the journal
│   ├── CorpusService.swift     # BM25 over the clinical corpus
│   ├── EmbeddingService.swift  # Optional E5 dense rerank
│   └── MemoryDiagnostics.swift # Unified-log snapshots + per-app ceiling probe
└── Resources/                  # de.lproj + en.lproj Localizable.strings, clinical corpus JSON

BegleiterTests/                 # XCTest unit tests
docs/
├── WRITEUP.md                  # Engineering writeup for the hackathon
├── DEMO_VIDEO.md               # 90-sec demo script + shot list
└── upstream-issue-gemma4-toolcall.md  # Filed against ml-explore/mlx-swift-lm
Project.md                      # Original full product specification
CHAT_README.md                  # Q&A pipeline design notes
```

## Privacy & data

- **Nothing leaves the device.** No network code is wired into any inference path. The only network call in the app is the one-time Hugging Face model download at first launch (gated by the Hub client).
- The clinical corpus the Ask path grounds on is restricted to open-access AIEOP-BFM publications, kinderkrebsinfo.de parent-education content, and EMA SmPCs. Bundled as `Begleiter/Resources/corpus.json`.
- The BFM 2017 protocol PDF is **not licensable** and **not** in this repo.

## License

Source code: MIT (see `LICENSE`).

The clinical corpus retains its sources' licences — see the per-document headers inside `Begleiter/Resources/corpus.json`.
