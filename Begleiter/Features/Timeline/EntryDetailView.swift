import AVFoundation
import SwiftUI

/// Detail view for a single `JournalEntry`. Shows raw text, all extracted
/// fields with confidence, lab values, reactions, and context metadata.
///
/// Editing arrives in iteration 7. For now this is read-only.
struct EntryDetailView: View {
    let entry: JournalEntry

    var body: some View {
        let fields = entry.extractedFields

        return Form {
            metadataSection
            if let filename = entry.rawVoiceAudioFilename,
               let audioURL = audioRecorderStoredURL(filename: filename) {
                Section {
                    AudioPlaybackRow(audioURL: audioURL)
                } header: {
                    Text(L10n.key("entryDetail.recording"))
                }
            }

            if !entry.rawPhotoFilenames.isEmpty {
                Section {
                    PhotoCarouselRow(filenames: entry.rawPhotoFilenames)
                } header: {
                    Text(L10n.key("entryDetail.photos"))
                }
            }

            if let raw = entry.rawText, !raw.isEmpty {
                Section {
                    Text(raw)
                        .font(.body)
                        .textSelection(.enabled)
                } header: {
                    Text(L10n.key("entryDetail.rawText"))
                }
            }

            if let summary = fields.summary {
                Section {
                    confidenceRow(label: summary.value, confidence: summary.confidence)
                } header: {
                    Text(L10n.key("entryDetail.summary"))
                }
            }

            if let drugs = fields.drugsMentioned, !drugs.value.isEmpty {
                Section {
                    ForEach(drugs.value, id: \.self) { drug in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drug.germanLabel).font(.body)
                            if let dose = drug.doseDescription {
                                Text(dose)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    confidenceFooter(drugs.confidence)
                } header: {
                    Text(L10n.key("entryDetail.drugs"))
                }
            }

            if let labs = fields.labValues, !labs.value.isEmpty {
                Section {
                    ForEach(labs.value, id: \.self) { lab in
                        LabValueRow(lab: lab)
                    }
                    confidenceFooter(labs.confidence)
                } header: {
                    Text(L10n.key("entryDetail.labs"))
                }
            }

            if let procs = fields.proceduresMentioned, !procs.value.isEmpty {
                Section {
                    ForEach(procs.value, id: \.self) { Text($0) }
                    confidenceFooter(procs.confidence)
                } header: {
                    Text(L10n.key("entryDetail.procedures"))
                }
            }

            if let decisions = fields.decisions, !decisions.value.isEmpty {
                Section {
                    ForEach(decisions.value, id: \.self) { Text($0) }
                    confidenceFooter(decisions.confidence)
                } header: {
                    Text(L10n.key("entryDetail.decisions"))
                }
            }

            if let obs = fields.parentObservations, !obs.value.isEmpty {
                Section {
                    ForEach(obs.value, id: \.self) { Text($0) }
                    confidenceFooter(obs.confidence)
                } header: {
                    Text(L10n.key("entryDetail.observations"))
                }
            }

            if let reactions = fields.reactions, !reactions.value.isEmpty {
                Section {
                    ForEach(reactions.value, id: \.self) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.description).font(.body)
                            HStack(spacing: 8) {
                                if let cause = r.suspectedCause {
                                    Text(cause)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let sev = r.parentSeverity {
                                    Text(sev.rawValue)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    confidenceFooter(reactions.confidence)
                } header: {
                    Text(L10n.key("entryDetail.reactions"))
                }
            }

            if let qs = fields.openQuestions, !qs.value.isEmpty {
                Section {
                    ForEach(qs.value, id: \.self) { Text($0) }
                    confidenceFooter(qs.confidence)
                } header: {
                    Text(L10n.key("entryDetail.questions"))
                }
            }

            if let raw = entry.rawExtractionResponse, !raw.isEmpty {
                Section {
                    DisclosureGroup(L10n.t("entryDetail.rawResponseToggle")) {
                        Text(raw)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                } footer: {
                    Text(L10n.key("entryDetail.rawResponseFooter"))
                }
            }
        }
        .navigationTitle(entry.visitDate.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var metadataSection: some View {
        Section {
            LabeledContent(
                L10n.t("entryDetail.phase"),
                value: NSLocalizedString("phase.\(entry.phase.rawValue).label", comment: "")
            )
            LabeledContent(
                L10n.t("entryDetail.dayInPhase"),
                value: "\(entry.dayInPhase)"
            )
            if let doctor = entry.extractedFields.doctorName?.value, !doctor.isEmpty {
                LabeledContent(L10n.t("entryDetail.doctor"), value: doctor)
            }
            if let visitType = entry.extractedFields.visitType?.value {
                LabeledContent(L10n.t("entryDetail.visitType"), value: visitType.germanLabel)
            }
        } header: {
            Text(L10n.key("entryDetail.context"))
        }
    }

    @ViewBuilder
    private func confidenceRow(label: String, confidence: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            ConfidenceBadge(confidence: confidence)
        }
    }

    @ViewBuilder
    private func confidenceFooter(_ confidence: Double) -> some View {
        HStack {
            Spacer()
            ConfidenceBadge(confidence: confidence)
        }
    }
}

private struct LabValueRow: View {
    let lab: LabValue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(lab.germanLabel).font(.body)
                Spacer()
                Text("\(formatted(lab.value)) \(lab.unit)")
                    .font(.body.monospacedDigit())
            }
            if let lo = lab.referenceMin, let hi = lab.referenceMax {
                Text("Referenz: \(formatted(lo))–\(formatted(hi)) \(lab.unit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

/// Horizontal carousel of saved photos. Tapping a thumbnail opens it
/// fullscreen via a NavigationLink for a closer look.
private struct PhotoCarouselRow: View {
    let filenames: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(filenames, id: \.self) { filename in
                    if let url = PhotoStorage.storedURL(for: filename),
                       let ui = UIImage(contentsOfFile: url.path) {
                        NavigationLink {
                            FullscreenPhotoView(image: ui)
                        } label: {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct FullscreenPhotoView: View {
    let image: UIImage
    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Bridge helper — calling the static method on `AudioRecorder` from a
/// view's body is awkward because AudioRecorder is `@available(iOS 26.0, *)`.
/// EntryDetailView itself is available everywhere; only audio playback
/// is iOS 26+ in practice (recordings made on older OSs simply don't
/// exist).
private func audioRecorderStoredURL(filename: String) -> URL? {
    guard let docs = try? FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask,
        appropriateFor: nil, create: false
    ) else { return nil }
    let url = docs.appendingPathComponent("voice", isDirectory: true)
        .appendingPathComponent(filename)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// Tiny play/pause row for a stored .m4a recording. Uses AVAudioPlayer so
/// it works on iOS 17+ regardless of the recorder's iOS 26+ gate.
private struct AudioPlaybackRow: View {
    let audioURL: URL
    @State private var controller: AudioPlaybackController?
    @State private var isPlaying = false

    var body: some View {
        Button {
            ensureController()
            if isPlaying {
                controller?.pause()
                isPlaying = false
            } else {
                controller?.play()
                isPlaying = true
            }
        } label: {
            HStack {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                Text(L10n.key(isPlaying ? "entryDetail.recordingPause" : "entryDetail.recordingPlay"))
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            ensureController()
            controller?.onFinish = {
                Task { @MainActor in isPlaying = false }
            }
        }
        .onDisappear {
            controller?.pause()
        }
    }

    private func ensureController() {
        if controller == nil {
            controller = AudioPlaybackController(url: audioURL)
        }
    }
}

@MainActor
private final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate {
    private let url: URL
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    init(url: URL) {
        self.url = url
    }

    func play() {
        if player == nil {
            do {
                player = try AVAudioPlayer(contentsOf: url)
                player?.delegate = self
                player?.prepareToPlay()
            } catch {
                return
            }
        }
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }
}

private struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        let pct = Int((confidence * 100).rounded())
        Text("\(pct)%")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(.primary)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch confidence {
        case 0.75...1.0: return .green.opacity(0.2)
        case 0.4..<0.75: return .yellow.opacity(0.25)
        default:         return .orange.opacity(0.25)
        }
    }
}
