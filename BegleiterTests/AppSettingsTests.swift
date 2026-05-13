import XCTest
@testable import Begleiter

/// Tests for the `AppSettings` UserDefaults facade and the enums that
/// back the Settings screen.
///
/// These guard the parts of the contract that aren't obvious from reading
/// the code:
/// - **Defaults** match what was hardcoded before the Settings screen
///   existed, so a fresh install changes no behaviour.
/// - **Round-trip** through UserDefaults is lossless for every key.
/// - **Invalid input** (a stale or corrupted raw string) falls back to
///   the safe default instead of crashing.
/// - **Raw values** of `ModelVariant` and `LabPipelineMode` are stable
///   strings — they're the persistence keys for every user, so renaming
///   a case silently would orphan their saved settings.
///
/// The Gemma generation path itself is exercised manually on a physical
/// iPhone (the simulator can't host MLX); these tests cover the pure-Swift
/// surface that wires settings into the services.
final class AppSettingsTests: XCTestCase {

    /// Keys we touch — captured here so `tearDown` can wipe them without
    /// guessing. Tests use `UserDefaults.standard` because `AppSettings`
    /// reads `.standard` directly; the alternative (refactor to inject
    /// defaults) added complexity for no real win.
    private let managedKeys = [
        AppSettings.modelVariantKey,
        AppSettings.extractionMaxTokensKey,
        AppSettings.briefingMaxTokensKey,
        AppSettings.handoffMaxTokensKey,
        AppSettings.labPipelineModeKey,
    ]

    override func setUp() {
        super.setUp()
        clearKeys()
    }

    override func tearDown() {
        clearKeys()
        super.tearDown()
    }

    private func clearKeys() {
        for key in managedKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Defaults

    func test_defaults_matchPreSettingsHardcodedValues() {
        // These constants were the call-site hardcoded values before the
        // Settings screen existed. Drifting from them means an upgrade
        // silently changes the model's behaviour for every existing user.
        XCTAssertEqual(AppSettings.extractionMaxTokens, 2500)
        XCTAssertEqual(AppSettings.briefingMaxTokens, 640)
        XCTAssertEqual(AppSettings.handoffMaxTokens, 512)
        XCTAssertEqual(AppSettings.modelVariant, .e2b)
        XCTAssertEqual(AppSettings.labPipelineMode, .ocrThenGemma)
    }

    // MARK: - Round-trip

    func test_persistModelVariant_roundTrips() {
        AppSettings.persistModelVariant(.e4b)
        XCTAssertEqual(AppSettings.modelVariant, .e4b)

        AppSettings.persistModelVariant(.e2b)
        XCTAssertEqual(AppSettings.modelVariant, .e2b)
    }

    func test_maxTokens_roundTripThroughUserDefaults() {
        UserDefaults.standard.set(1024, forKey: AppSettings.extractionMaxTokensKey)
        UserDefaults.standard.set(320,  forKey: AppSettings.briefingMaxTokensKey)
        UserDefaults.standard.set(768,  forKey: AppSettings.handoffMaxTokensKey)

        XCTAssertEqual(AppSettings.extractionMaxTokens, 1024)
        XCTAssertEqual(AppSettings.briefingMaxTokens, 320)
        XCTAssertEqual(AppSettings.handoffMaxTokens, 768)
    }

    func test_labPipelineMode_roundTrips() {
        UserDefaults.standard.set(
            LabPipelineMode.directMultimodal.rawValue,
            forKey: AppSettings.labPipelineModeKey
        )
        XCTAssertEqual(AppSettings.labPipelineMode, .directMultimodal)
    }

    // MARK: - Invalid-input fallback

    /// A stale or hand-edited UserDefaults entry must never crash the
    /// service layer. Old install, renamed enum, deliberate corruption
    /// via Settings.app — all should land on a safe default.
    func test_modelVariant_invalidRawString_fallsBackToE2B() {
        UserDefaults.standard.set("garbage-not-a-variant", forKey: AppSettings.modelVariantKey)
        XCTAssertEqual(AppSettings.modelVariant, .e2b)
    }

    func test_labPipelineMode_invalidRawString_fallsBackToOCR() {
        UserDefaults.standard.set("malformed-mode", forKey: AppSettings.labPipelineModeKey)
        XCTAssertEqual(AppSettings.labPipelineMode, .ocrThenGemma)
    }

    /// Zero is the value `UserDefaults.integer(forKey:)` returns for an
    /// unset key, which is also a useless `maxTokens` budget. The getter
    /// must treat zero as "use the default" so a misconfigured key never
    /// produces an empty generation.
    func test_extractionMaxTokens_zeroFallsBackToDefault() {
        UserDefaults.standard.set(0, forKey: AppSettings.extractionMaxTokensKey)
        XCTAssertEqual(AppSettings.extractionMaxTokens, AppSettings.defaultExtractionMaxTokens)
    }

    // MARK: - Raw-string stability

    /// Raw values for these enums are written to UserDefaults on every
    /// user's device. Renaming a case = orphaning their saved setting.
    /// Locking the strings here forces a deliberate migration if anyone
    /// ever wants to change them.
    func test_modelVariant_rawValues_areStable() {
        XCTAssertEqual(ModelVariant.e2b.rawValue, "e2b")
        XCTAssertEqual(ModelVariant.e4b.rawValue, "e4b")
    }

    func test_labPipelineMode_rawValues_areStable() {
        XCTAssertEqual(LabPipelineMode.ocrThenGemma.rawValue, "ocrThenGemma")
        XCTAssertEqual(LabPipelineMode.directMultimodal.rawValue, "directMultimodal")
    }

    /// HuggingFace model IDs surface in the Diagnostics section of the
    /// Settings screen. A typo here would download nothing or the wrong
    /// weights, so the strings are pinned.
    func test_modelVariant_modelId_pointsAtMlxCommunityWeights() {
        XCTAssertEqual(ModelVariant.e2b.modelId, "mlx-community/gemma-4-e2b-it-4bit")
        XCTAssertEqual(ModelVariant.e4b.modelId, "mlx-community/gemma-4-e4b-it-4bit")
    }

    func test_modelVariant_displayName_isNonEmpty() {
        for variant in ModelVariant.allCases {
            XCTAssertFalse(variant.displayName.isEmpty,
                           "displayName missing for \(variant.rawValue)")
        }
    }
}
