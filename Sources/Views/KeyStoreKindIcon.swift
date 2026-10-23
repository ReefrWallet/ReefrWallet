import SwiftUI

/// Sidebar glyph for a key store's kind.
struct KeyStoreKindIcon: View {
    let kind: KeyStore.Kind
    /// Hardware model, e.g. `Safe 5`.
    var model: String?

    var body: some View {
        switch kind {
        case .local:
            makeImage("localKey16")
        case .trezor:
            makeImage(isOldTrezor ? "trezorOld16" : "trezor16")
        case .watchOnly:
            EmptyView()
        }
    }

    /// Trezors before the Safe 5 (One, Model T, Safe 3) use the old glyph.
    private var isOldTrezor: Bool {
        guard let model else {
            return false
        }

        return !["Safe 5", "Safe 7"].contains(model)
    }

    private func makeImage(_ name: String) -> some View {
        Image(name)
            .resizable()
            .frame(width: 16, height: 16)
    }
}
