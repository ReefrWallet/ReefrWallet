//
//  Account.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//


public protocol AccountProtocol: AnyObject {
    var blockchain: Blockchain { get }
    var derivationPath: DerivationPath { get }
    var curve: Curve { get }
    var source: KeySource { get }
    var publicKey: PublicKey { get }
}

public final class Account: AccountProtocol {
    public let blockchain: Blockchain
    public let derivationPath: DerivationPath
    public let curve: Curve
    public let source: KeySource
    public let publicKey: PublicKey

    init(blockchain: Blockchain, derivationPath: DerivationPath, curve: Curve, source: KeySource, publicKey: PublicKey) {
        self.blockchain = blockchain
        self.derivationPath = derivationPath
        self.curve = curve
        self.source = source
        self.publicKey = publicKey
    }
}
