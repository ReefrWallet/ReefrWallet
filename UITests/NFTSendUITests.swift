import BigInt
import Foundation
import XCTest
import WalletKitTesting

/// NFTs tab on a local anvil node: mock ERC-721 and ERC-1155 tokens are listed
/// from the node's logs and sent through the Send NFT sheet.
@MainActor
final class NFTSendUITests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"
    private var app: XCUIApplication!
    private var anvilNode: EthereumNode!
    private var recipientAddress = ""

    override func setUp() async throws {
        continueAfterFailure = false
        try requireASCIIKeyboardLayout()

        anvilNode = try await EthereumNode.start()
        recipientAddress = try await mintNFTs(node: anvilNode)

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = [
            "--test",
            "--mnemonic",
            mnemonic,
            "--evm-rpc-url",
            anvilNode.endpoint.absoluteString,
            "--create-evm-accounts"
        ]
    }

    override func tearDown() {
        anvilNode?.stop()
        anvilNode = nil
        app = nil
    }

    func testSendsERC721AndPartOfERC1155() {
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let account = app.nftDescendant(withIdentifier: "sidebar-account-label-Sepolia #1")
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        account.click()

        let tab = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "NFTs")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.click()

        let unique = app.nftDescendant(withIdentifier: "nft-row-7")
        let multiple = app.nftDescendant(withIdentifier: "nft-row-3")
        XCTAssertTrue(unique.waitForExistence(timeout: 30), "Expected the minted ERC-721 to be listed.")
        XCTAssertTrue(multiple.waitForExistence(timeout: 10), "Expected the minted ERC-1155 to be listed.")
        let count = app.nftDescendant(withIdentifier: "account-nfts-count")
        XCTAssertTrue(count.waitForText("2 NFTs", timeout: 10), "Expected the header to count 2 NFTs, got \(count.text).")

        send(unique, quantity: nil)
        XCTAssertTrue(unique.waitUntilGoneForNFT(timeout: 30), "Expected the sent ERC-721 to leave the table.")
        XCTAssertTrue(count.waitForText("1 NFT", timeout: 10), "Expected the header to count 1 NFT, got \(count.text).")

        send(multiple, quantity: "2")
        let remaining = app.nftDescendant(withIdentifier: "nft-quantity-3")
        XCTAssertTrue(remaining.waitForExistence(timeout: 10), "Expected the ERC-1155 row to remain.")
        XCTAssertTrue(remaining.waitForText("3", timeout: 30), "Expected 3 of the ERC-1155 to remain, got \(remaining.text).")
    }

    private func send(_ row: XCUIElement, quantity: String?) {
        row.click()

        let sendButton = app.nftDescendant(withIdentifier: "account-send-nft-button")
        XCTAssertTrue(sendButton.waitUntilEnabledForNFT(timeout: 10), "Expected Send to enable for the selected NFT.")
        sendButton.click()

        if let quantity {
            let quantityField = app.nftDescendant(withIdentifier: "nft-transfer-quantity-field")
            XCTAssertTrue(quantityField.waitForExistence(timeout: 5))
            quantityField.click()
            quantityField.typeKey("a", modifierFlags: .command)
            quantityField.typeText(quantity)
        }

        let receiverField = app.nftDescendant(withIdentifier: "nft-transfer-receiver-field")
        XCTAssertTrue(receiverField.waitForExistence(timeout: 5))
        receiverField.click()
        receiverField.typeText(recipientAddress)

        let nextButton = app.nftDescendant(withIdentifier: "nft-transfer-next-button")
        XCTAssertTrue(nextButton.waitUntilEnabledForNFT(timeout: 10), "Expected Next once fees are estimated.")
        nextButton.click()

        let title = app.nftDescendant(withIdentifier: "nft-transfer-sheet-title")
        XCTAssertTrue(title.waitUntilGoneForNFT(timeout: 60), "Expected the sheet to close once the send confirmed.")
    }

    /// Mints ERC-721 #7 and 5 of ERC-1155 #3 to `Sepolia #1`; returns `Sepolia #2`'s address.
    private func mintNFTs(node: EthereumNode) async throws -> String {
        let seed = try Mnemonic.fromPhrase(mnemonic).toSeed()
        let signers = try (0 ..< 2).map { index in
            let path = try DerivationPath(string: "m/44'/60'/0'/0/\(index)")
            let key = try seed.masterKey(curve: .secp256k1).derive(path).privateKey()
            return try EthereumPKeySigner(chainId: node.chainId, privateKey: key, derivationPath: path)
        }

        let owner = try signers[0].address()

        for signer in signers {
            try await node.setBalance(signer.address(), wei: 10_000_000_000_000_000_000)
        }

        let erc721 = try await node.deployMockERC721(signer: signers[0])
        let erc1155 = try await node.deployMockERC1155(signer: signers[0])
        try await node.mintERC721(signer: signers[0], contract: erc721, recipient: owner, id: 7)
        try await node.mintERC1155(signer: signers[0], contract: erc1155, recipient: owner, id: 3, amount: 5)

        return try signers[1].address().string
    }
}

private extension XCUIApplication {
    func nftDescendant(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}

private extension XCUIElement {
    func waitForText(_ expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if exists, text == expected {
                return true
            }

            _ = waitForExistence(timeout: 0.2)
        }

        return exists && text == expected
    }

    func waitUntilEnabledForNFT(timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if exists, isEnabled {
                return true
            }

            _ = waitForExistence(timeout: 0.2)
        }

        return exists && isEnabled
    }

    func waitUntilGoneForNFT(timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while Date.now < deadline {
            if !exists {
                return true
            }

            _ = waitForExistence(timeout: 0.2)
        }

        return !exists
    }
}
