#if DEBUG
import SwiftData
import SwiftUI
import WalletKit

/// The tab's states from the Penpot `Main / Account Staking / Solana` screens.
@MainActor
private enum SolanaStakingPreview {
    nonisolated static let owner = "7EcDhSYGxXyscsWJ3CFLtVvAuLKTzXwCFLtV"

    static func account() -> Account {
        // Previews have no store, but an account needs a key store's identifier.
        // swiftlint:disable:next force_try
        let container = try! ModelContainer(
            for: KeyStoreModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let context = ModelContext(container)
        let keyStore = KeyStoreModel(.watchOnly, name: "Main Wallet")
        context.insert(keyStore)

        return Account(
            address: owner,
            blockchain: .solana(.devnet),
            derivationPath: nil,
            keyStoreId: keyStore.persistentModelID,
            name: "Solana #1",
            // Nothing listens here: previews never reach a real node.
            rpcURLOverride: URL(string: "http://127.0.0.1:1")
        )
    }

    static func position(
        _ address: String,
        voter: String,
        stake: UInt64,
        status: SolanaStakeStatus,
        staker: String = owner,
        withdrawer: String = owner,
        lockup: Int64 = 0
    ) -> SolanaStakePosition {
        SolanaStakePosition(
            account: SolanaStakeAccount(
                address: address,
                delegation: .init(activationEpoch: 1, deactivationEpoch: .max, stake: stake, voter: voter),
                lamports: stake + 2_282_880,
                lockup: .init(custodian: "", epoch: 0, unixTimestamp: lockup),
                rentExemptReserve: 2_282_880,
                staker: staker,
                withdrawer: withdrawer
            ),
            activation: .init(),
            status: status
        )
    }

    static func details(
        positions: [SolanaStakePosition],
        rewards: SolanaStakingRewards? = SolanaStakingRewards(
            attemptedAt: Date(),
            epoch: 1_077,
            lamports: 4_100_000,
            queriedAddresses: ["a"],
            unknownAddresses: []
        ),
        discovery: SolanaStakeDiscovery = .complete,
        pending: [SolanaPendingSubmission] = []
    ) -> SolanaStakingDetails {
        SolanaStakingDetails(
            clock: SolanaClock(epoch: 1_078, epochStartTimestamp: 0, slot: 0, unixTimestamp: 1_000),
            discovery: discovery,
            observedAt: Date(),
            pendingSubmissions: pending,
            positions: positions,
            retiredAddresses: [:],
            rewards: rewards,
            slotDuration: 0.21,
            slotsRemainingInEpoch: 103_000,
            validators: [
                "everstake": .init(commission: 7, name: "Everstake", apy: 6.84),
                "helius": .init(commission: 5, name: "Helius", apy: 6.84),
                "figment": .init(commission: 5, name: "Figment", apy: 6.84),
                "solflare": .init(commission: 5, name: "Solflare", apy: 6.84),
                "kiln": .init(commission: 5, name: "Kiln", apy: 6.84)
            ]
        )
    }

    static let earning = [
        position("a", voter: "everstake", stake: 8_250_000_000, status: .active),
        position("b", voter: "helius", stake: 2_000_000_000, status: .activating)
    ]

    static var mixed: [SolanaStakePosition] {
        earning + [
            position("c", voter: "figment", stake: 3_000_000_000, status: .deactivating),
            position("d", voter: "solflare", stake: 1_500_000_000, status: .inactive)
        ]
    }

    static var restricted: [SolanaStakePosition] {
        [
            position("a", voter: "everstake", stake: 8_250_000_000, status: .active),
            position("b", voter: "solflare", stake: 1_500_000_000, status: .active, lockup: 9_999),
            position("c", voter: "figment", stake: 3_000_000_000, status: .active, staker: "other"),
            position("d", voter: "kiln", stake: 1_000_000_000, status: .active, withdrawer: "other")
        ]
    }

    static func view(
        _ details: SolanaStakingDetails?,
        canSign: Bool = true,
        error: String? = nil
    ) -> some View {
        let model = SolanaStakingModel(
            account: account(),
            canSign: canSign,
            details: details,
            error: error,
            solPrice: 100
        )

        return VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Spacer()
                SolanaStakingToolbarActions(model: model)
                    .fixedSize()
            }
            .padding(.horizontal)
            #endif

            #if os(iOS)
            List {
                SolanaStakingView(model: model)
            }
            .listStyle(.plain)
            #else
            SolanaStakingView(model: model)
            #endif
        }
        .frame(width: isPhone ? nil : 860, height: isPhone ? nil : 480)
    }
}

/// Sheets read through the services, so these use the in-memory container.
@MainActor
private func sheet(_ kind: SolanaStakingSheetKind, positions: [SolanaStakePosition]) -> some View {
    Inject.mode = .preview

    return SolanaStakingSheet(
        kind: kind,
        model: SolanaStakingModel(
            account: SolanaStakingPreview.account(),
            canSign: true,
            details: SolanaStakingPreview.details(positions: positions),
            solPrice: 100
        )
    )
}

#Preview("Sheet: Stake") {
    sheet(.stake, positions: SolanaStakingPreview.earning)
}

#Preview("Sheet: Unstake") {
    sheet(.unstake, positions: SolanaStakingPreview.restricted)
}

#Preview("Sheet: Withdraw") {
    sheet(.withdraw, positions: [
        SolanaStakingPreview.position("a", voter: "figment", stake: 1_500_000_000, status: .inactive),
        SolanaStakingPreview.position("b", voter: "kiln", stake: 1_000_000_000, status: .inactive, withdrawer: "other"),
        SolanaStakingPreview.position("c", voter: "solflare", stake: 1_500_000_000, status: .inactive, lockup: 9_999)
    ])
}

#Preview("Mixed") {
    SolanaStakingPreview.view(SolanaStakingPreview.details(positions: SolanaStakingPreview.mixed))
}

#Preview("Not Staked") {
    SolanaStakingPreview.view(SolanaStakingPreview.details(positions: [], rewards: nil))
}

#Preview("Watch Only") {
    SolanaStakingPreview.view(SolanaStakingPreview.details(positions: SolanaStakingPreview.mixed), canSign: false)
}

#Preview("Restricted") {
    SolanaStakingPreview.view(SolanaStakingPreview.details(positions: SolanaStakingPreview.restricted))
}

#Preview("Notices") {
    SolanaStakingPreview.view(
        SolanaStakingPreview.details(positions: SolanaStakingPreview.earning, discovery: .degraded),
        error: "The network connection was lost."
    )
}

#Preview("Unresolved") {
    SolanaStakingPreview.view(SolanaStakingPreview.details(
        positions: SolanaStakingPreview.earning,
        pending: [SolanaPendingSubmission(
            action: .stake(lamports: 5_000_000_000, voter: "everstake"),
            isPastValidity: true,
            lastValidBlockHeight: 1,
            recentBlockhash: "",
            signature: "5Kd3xxxxxxxxxxxxxxxxxxxxxxxx9xQa",
            slotAtBuild: 1
        )]
    ))
}
#endif
