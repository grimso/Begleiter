import SwiftUI

/// Profile tab in the root `TabView`. Wraps `SettingsView` in its own
/// `NavigationStack` so the existing settings navigation title and any
/// pushed detail screens still work inside the tab.
struct ProfileTabView: View {
    var body: some View {
        NavigationStack {
            SettingsView()
        }
    }
}
