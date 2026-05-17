import SwiftUI

struct ArmView: View {
    @Bindable var model: OnboardingViewModel
    let onNext: () -> Void

    var body: some View {
        Form {
            Section {
                ForEach(model.armOptions, id: \.self) { arm in
                    ArmRow(
                        arm: arm,
                        isSelected: model.randomizationArm == arm,
                        onTap: { model.randomizationArm = arm }
                    )
                }
            } header: {
                Text(L10n.key("onboarding.arm.subtitle"))
            } footer: {
                Text(L10n.key("onboarding.arm.caption"))
            }
            .listRowBackground(Color("BegleiterCardSurface"))

            Section {
                Button {
                    onNext()
                } label: {
                    Text(L10n.key("app.continue"))
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.randomizationArm == nil)
            }
            .listRowBackground(Color("BegleiterCardSurface"))
        }
        .navigationTitle(L10n.key("onboarding.arm.title"))
        .scrollContentBackground(.hidden)
        .background(Color("BegleiterBackground").ignoresSafeArea())
    }
}

private struct ArmRow: View {
    let arm: RandomizationArm
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(L10n.key("arm.\(arm.rawValue).label"))
                    .foregroundStyle(.primary)
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
