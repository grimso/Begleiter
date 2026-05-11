import SwiftUI

struct RiskGroupView: View {
    @Bindable var model: OnboardingViewModel
    let onNext: () -> Void

    var body: some View {
        Form {
            Section {
                ForEach(RiskGroup.allCases, id: \.self) { group in
                    RiskGroupRow(
                        group: group,
                        isSelected: model.riskGroup == group,
                        onTap: { select(group) }
                    )
                }
            } header: {
                Text(L10n.key("onboarding.riskGroup.subtitle"))
            } footer: {
                Text(L10n.key("onboarding.riskGroup.caption"))
            }

            Section {
                Button {
                    onNext()
                } label: {
                    Text(L10n.key("app.continue"))
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.riskGroup == nil)
            }
        }
        .navigationTitle(L10n.key("onboarding.riskGroup.title"))
    }

    /// Selecting a different risk group invalidates an arm choice that may
    /// no longer be compatible, so we clear it.
    private func select(_ group: RiskGroup) {
        if model.riskGroup != group {
            model.randomizationArm = nil
        }
        model.riskGroup = group
    }
}

private struct RiskGroupRow: View {
    let group: RiskGroup
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.key("risk.\(group.rawValue).label"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(L10n.key("risk.\(group.rawValue).description"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
