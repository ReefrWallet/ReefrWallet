import Foundation

extension LocalizedStringResource {
    /// Resolves the resource to a `String` without a non-literal `String(localized:)` call at each site.
    var string: String {
        String(localized: self)
    }
}
