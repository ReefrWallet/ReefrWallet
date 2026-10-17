import SwiftUI

/// Sidebar glyph for a key store's kind.
struct KeyStoreKindIcon: View {
    let kind: KeyStore.Kind

    var body: some View {
        switch kind {
        case .local:
            // Wallet body is short relative to its antennas: draw larger and lower.
            makeImage("LocalKeyIcon", height: 19)
                .offset(y: 1)
        case .trezor:
            makeImage("TrezorIcon", height: 16)
        case .watchOnly:
            EmptyView()
        }
    }

    private func makeImage(_ name: String, height: CGFloat) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .frame(width: 16, height: 16)
    }
}
