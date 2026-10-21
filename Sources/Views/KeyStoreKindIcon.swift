import SwiftUI

/// Sidebar glyph for a key store's kind.
struct KeyStoreKindIcon: View {
    let kind: KeyStore.Kind

    var body: some View {
        switch kind {
        case .local:
            makeImage("localKey16")
        case .trezor:
            makeImage("trezor16")
        case .watchOnly:
            EmptyView()
        }
    }

    private func makeImage(_ name: String) -> some View {
        Image(name)
            .resizable()
            .frame(width: 16, height: 16)
    }
}
