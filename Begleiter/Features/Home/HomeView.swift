import SwiftData
import SwiftUI
import UIKit

/// Home tab in the root `TabView`. Visual identity:
///
/// - Warm parchment background (`BegleiterBackground`) with a serif italic
///   wordmark flanked by thin rules and a time-of-day greeting.
/// - Optional `Image("crane")` illustration above the greeting (renders only
///   when the asset is present; otherwise the slot collapses to zero height).
/// - Three primary cards (Tagebuch / Blutwerte / Fragen) with circular
///   dark-teal icon containers.
/// - A small beige encouragement pill at the bottom.
///
/// Tap routing:
/// - Tagebuch → switches the parent `TabView` to the Timeline tab.
/// - Blutwerte → presents `LabValuesView` as a sheet.
/// - Fragen → presents `AskView(scope: .all)` as a sheet.
///
/// No toolbar. Add-entry, Vorbereitung, and Übergabe live on the Timeline
/// tab; Einstellungen lives on the Profile tab.
struct HomeView: View {
    let child: ChildState
    @Binding var selectedTab: HomeTab

    @State private var presentingLabs = false
    @State private var presentingAsk = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero
                greetingBlock
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
    }

    // MARK: - Hero (wordmark · crane · tagline)

    private var hero: some View {
        VStack(spacing: 14) {
            wordmarkBlock
            craneIllustration
            taglineBlock
        }
        .padding(.top, 8)
    }

    private var wordmarkBlock: some View {
        VStack(spacing: 6) {
            rule
                .frame(maxWidth: 220)
            Text(L10n.key("app.name"))
                .font(.system(size: 38, weight: .bold, design: .serif).italic())
                .foregroundStyle(Color("BegleiterPrimary"))
            rule
                .frame(maxWidth: 220)
        }
    }

    @ViewBuilder
    private var craneIllustration: some View {
        if UIImage(named: "crane") != nil {
            Image("crane")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 140)
                .frame(maxWidth: .infinity)
        }
    }

    private var taglineBlock: some View {
        HStack(spacing: 12) {
            rule
            Text(L10n.key("home.tagline"))
                .font(.system(.callout, design: .serif).italic())
                .foregroundStyle(Color("BegleiterAccent"))
                .fixedSize(horizontal: true, vertical: false)
            rule
        }
        .padding(.horizontal, 32)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color("BegleiterDivider"))
            .frame(height: 0.6)
    }

    // MARK: - Greeting

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.key(greetingKey))
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color("BegleiterPrimary"))
            Text(L10n.key("home.greeting.subheader"))
                .font(.subheadline.italic())
                .foregroundStyle(Color("BegleiterPrimary").opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greetingKey: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12:  return "home.greeting.morning"
        case 12..<18: return "home.greeting.afternoon"
        default:      return "home.greeting.evening"
        }
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
        }
    }

    // MARK: - Encouragement

    private var encouragementPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "face.smiling")
                .font(.footnote)
                .foregroundStyle(Color("BegleiterAccent"))
            Text(L10n.key("home.encouragement"))
                .font(.footnote)
                .foregroundStyle(Color("BegleiterPrimary").opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color("BegleiterPillSurface"))
        .clipShape(Capsule())
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
