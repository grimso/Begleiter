import SwiftUI

/// Profile tab in the root `TabView`. Owns a `NavigationStack` and hosts
/// `ProfileLandingView` — a small list with two pushable destinations:
/// **Behandlung** (clinical state from onboarding) and **Entwicklung**
/// (developer settings).
struct ProfileTabView: View {
    let child: ChildState

    var body: some View {
        NavigationStack {
            ProfileLandingView(child: child)
        }
    }
}
