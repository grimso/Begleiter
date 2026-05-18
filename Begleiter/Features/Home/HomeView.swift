import SwiftData
import SwiftUI

/// Home tab in the root `TabView`. Visual identity:
///
/// - Warm parchment background (`BegleiterBackground`) with the app-icon
///   logo and a serif italic tagline at the top.
/// - Five primary cards (Tagebuch / Blutwerte / Fragen / Vorbereitung /
///   Übergabe) with circular dark-teal icon containers.
/// - A small beige encouragement pill at the bottom.
///
/// Tap routing:
/// - Tagebuch → switches the parent `TabView` to the Timeline tab.
/// - Blutwerte → presents `LabValuesView` as a sheet.
/// - Fragen → presents `AskView(scope: .all)` as a sheet.
/// - Vorbereitung → presents `PreVisitBriefingView` as a sheet.
/// - Übergabe → presents `HandoffDocumentView` as a sheet.
///
/// No toolbar. Add-entry lives on the Timeline tab; Vorbereitung and
/// Übergabe are also reachable from the Timeline toolbar; Einstellungen
/// lives on the Profile tab.
struct HomeView: View {
    let child: ChildState
    @Binding var selectedTab: HomeTab

    @State private var presentingLabs = false
    @State private var presentingAsk = false
    @State private var presentingBriefing = false
    @State private var presentingHandoff = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero
                cards
                encouragementPill
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color("BegleiterBackground").ignoresSafeArea())
        .sheet(isPresented: $presentingLabs) {
            LabValuesView(child: child)
        }
        .sheet(isPresented: $presentingAsk) {
            AskView(child: child, scope: .all)
        }
        .sheet(isPresented: $presentingBriefing) {
            PreVisitBriefingView(child: child)
        }
        .sheet(isPresented: $presentingHandoff) {
            HandoffDocumentView(child: child)
        }
    }

    // MARK: - Hero (app-icon logo + tagline)

    private var hero: some View {
        VStack(spacing: 12) {
            Image("CompanionLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
            Text(L10n.key("home.tagline"))
                .font(.system(.subheadline, design: .serif).italic())
                .foregroundStyle(Color("BegleiterAccent"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.top, 8)
    }

    // MARK: - Cards

    private var cards: some View {
        VStack(spacing: 12) {
            Button {
                selectedTab = .timeline
            } label: {
                HomeCardLabel(
                    icon: "book.closed",
                    titleKey: "home.card.journal.title",
                    subtitleKey: "home.card.journal.subtitle"
                )
            }
            .buttonStyle(.plain)

            Button {
                presentingLabs = true
            } label: {
                HomeCardLabel(
                    icon: "testtube.2",
                    titleKey: "home.card.labs.title",
                    subtitleKey: "home.card.labs.subtitle"
                )
            }
            .buttonStyle(.plain)

            Button {
                presentingAsk = true
            } label: {
                HomeCardLabel(
                    icon: "bubble.left.and.text.bubble.right",
                    titleKey: "home.card.ask.title",
                    subtitleKey: "home.card.ask.subtitle"
                )
            }
            .buttonStyle(.plain)

            Button {
                presentingBriefing = true
            } label: {
                HomeCardLabel(
                    icon: "calendar.badge.clock",
                    titleKey: "home.card.briefing.title",
                    subtitleKey: "home.card.briefing.subtitle"
                )
            }
            .buttonStyle(.plain)

            Button {
                presentingHandoff = true
            } label: {
                HomeCardLabel(
                    icon: "doc.text",
                    titleKey: "home.card.handoff.title",
                    subtitleKey: "home.card.handoff.subtitle"
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Encouragement

    private var encouragementPill: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "face.smiling")
                .font(.footnote)
                .foregroundStyle(Color("BegleiterAccent"))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.key("home.footer.line1"))
                    .font(.footnote)
                    .foregroundStyle(Color("BegleiterPrimary").opacity(0.8))
                Text(L10n.key("home.footer.line2"))
                    .font(.caption2)
                    .foregroundStyle(Color("BegleiterPrimary").opacity(0.55))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color("BegleiterPillSurface"))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.top, 4)
    }
}

/// Primary card on `HomeView`. White SF symbol inside a dark-teal circle on
/// the left; title + subtitle in the middle; sage chevron on the right.
private struct HomeCardLabel: View {
    let icon: String
    let titleKey: String
    let subtitleKey: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color("BegleiterPrimary"))
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.key(titleKey))
                    .font(.headline)
                    .foregroundStyle(Color("BegleiterPrimary"))
                Text(L10n.key(subtitleKey))
                    .font(.footnote)
                    .foregroundStyle(Color("BegleiterPrimary").opacity(0.65))
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color("BegleiterAccent"))
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background(Color("BegleiterCardSurface"))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color("BegleiterDivider"), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}
