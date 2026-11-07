#if DEBUG
import BigInt
import SwiftData
import SwiftUI
import WalletKit

/// The tab's states from the Penpot `Main / Account Staking / Cardano` screens.
@MainActor
private enum CardanoStakingPreview {
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
            address: "cardano:preprod:xpub",
            blockchain: .cardano(.preprod),
            derivationPath: nil,
            keyStoreId: keyStore.persistentModelID,
            name: "Cardano #1",
            // Nothing listens here: previews never reach a real node.
            rpcURLOverride: URL(string: "http://127.0.0.1:1")
        )
    }

    static func details(
        registered: Bool = true,
        drep: CardanoDRep? = .abstain,
        pending: [CardanoPendingSubmission] = [],
        workflow: CardanoStakingWorkflow? = nil
    ) -> CardanoStakingDetails {
        CardanoStakingDetails(
            drep: drep,
            drepName: nil,
            epoch: CardanoEpochTiming(endTime: Date().addingTimeInterval(2 * 86_400), epoch: 512),
            latestReward: CardanoReward(amount: 1_350_000, epoch: 511),
            pendingSubmissions: pending,
            pool: registered ? .init(poolId: "pool1everstake", pool: CardanoPool(
                fixedCost: 170_000_000,
                marginCost: 0.02,
                name: "Everstake",
                poolId: "pool1everstake",
                saturation: 0.62,
                ticker: "EVER"
            )) : nil,
            refundDeposit: 2_000_000,
            registered: registered,
            totalEarned: 96_200_000,
            workflow: workflow
        )
    }

    static func view(
        _ details: CardanoStakingDetails,
        canSign: Bool = true,
        error: String? = nil
    ) -> some View {
        Inject.mode = .preview

        let model = CardanoStakingModel(
            account: account(),
            canSign: canSign,
            details: details,
            delegatedStake: 1_250_000_000,
            rewards: 12_480_000,
            error: error,
            adaPrice: 0.4
        )

        return VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Spacer()
                CardanoStakingToolbarActions(model: model)
                    .fixedSize()
            }
            .padding(.horizontal)
            #endif

            #if os(iOS)
            List {
                CardanoStakingView(model: model)
            }
            .listStyle(.plain)
            #else
            CardanoStakingView(model: model)
            #endif
        }
        .frame(width: isPhone ? nil : 860, height: isPhone ? nil : 560)
    }
}

/// Sheets read through the services, so these use the in-memory container.
@MainActor
private func sheet(_ kind: CardanoStakingSheetKind, details: CardanoStakingDetails) -> some View {
    Inject.mode = .preview

    return CardanoStakingSheet(
        kind: kind,
        model: CardanoStakingModel(
            account: CardanoStakingPreview.account(),
            canSign: true,
            details: details,
            delegatedStake: 1_250_000_000,
            rewards: 12_480_000,
            adaPrice: 0.4
        )
    )
}

#Preview("Delegated") {
    CardanoStakingPreview.view(CardanoStakingPreview.details())
}

#Preview("Not Staked") {
    CardanoStakingPreview.view(CardanoStakingPreview.details(registered: false, drep: nil))
}

#Preview("Continue") {
    CardanoStakingPreview.view(CardanoStakingPreview.details(
        drep: .abstain,
        workflow: CardanoStakingWorkflow(
            drep: .abstain,
            intent: .withdraw,
            phase: .readyForFinalStep(notice: nil),
            updatedAt: Date()
        )
    ))
}

#Preview("Unresolved") {
    CardanoStakingPreview.view(CardanoStakingPreview.details(
        pending: [CardanoPendingSubmission(hash: "9f2c\(String(repeating: "x", count: 56))a41e", ttl: 1)]
    ))
}

#Preview("Watch Only") {
    CardanoStakingPreview.view(CardanoStakingPreview.details(), canSign: false)
}

#Preview("Sheet: Stake") {
    sheet(.stake, details: CardanoStakingPreview.details(registered: false, drep: nil))
}

#Preview("Sheet: Withdraw Step 1") {
    sheet(.withdraw, details: CardanoStakingPreview.details(drep: nil))
}

#Preview("Sheet: Stop Staking") {
    sheet(.stopStaking, details: CardanoStakingPreview.details())
}
#endif
