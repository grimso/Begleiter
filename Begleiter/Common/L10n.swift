import Foundation
import SwiftUI

/// Thin wrapper around `NSLocalizedString` so call sites can use
/// `L10n.t("onboarding.welcome.title")` instead of the longer call.
///
/// SwiftUI `Text(L10n.key(...))` accepts a `LocalizedStringKey` which gives
/// SwiftUI a chance to perform its own lookup; both forms are supported here.
enum L10n {
    /// Resolve a string for direct use in non-SwiftUI code.
    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "")
        if args.isEmpty { return format }
        return String(format: format, arguments: args)
    }

    /// `LocalizedStringKey` for SwiftUI `Text(...)`.
    static func key(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }
}
