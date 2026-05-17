import SwiftUI

struct DiagnosisDateView: View {
    @Bindable var model: OnboardingViewModel
    let onNext: () -> Void

    /// We bind the DatePicker to a non-optional local date so the picker is
    /// always populated; the model field stays nil until the parent taps
    /// "Continue", at which point we commit the chosen date.
    @State private var selectedDate: Date = .now

    private var earliestAllowed: Date {
        // Allow up to ~3 years back — covers a full BFM treatment journey.
        Calendar.current.date(byAdding: .year, value: -3, to: .now) ?? .now
    }

    var body: some View {
        Form {
            Section {
                DatePicker(
                    selection: $selectedDate,
                    in: earliestAllowed...Date.now,
                    displayedComponents: .date
                ) {
                    Text(L10n.key("onboarding.diagnosisDate.label"))
                }
                .datePickerStyle(.graphical)
            } header: {
                Text(L10n.key("onboarding.diagnosisDate.subtitle"))
            } footer: {
                Text(L10n.key("onboarding.diagnosisDate.caption"))
            }
            .listRowBackground(Color("BegleiterCardSurface"))

            Section {
                Button {
                    model.diagnosisDate = selectedDate
                    onNext()
                } label: {
                    Text(L10n.key("app.continue"))
                        .frame(maxWidth: .infinity)
                }
            }
            .listRowBackground(Color("BegleiterCardSurface"))
        }
        .navigationTitle(L10n.key("onboarding.diagnosisDate.title"))
        .scrollContentBackground(.hidden)
        .background(Color("BegleiterBackground").ignoresSafeArea())
        .onAppear {
            if let existing = model.diagnosisDate {
                selectedDate = existing
            }
        }
    }
}
