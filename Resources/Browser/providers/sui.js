// providers/sui.js — Sui Wallet Standard provider, injected after
// bridge.js, wallet-standard-core.js and sui-sdk.js. Registers a Wallet
// Standard `Wallet` (sui:* features per @mysten/wallet-standard) over
// `window.__reefr.request('sui', ...)`.
//
// signTransaction/signAndExecuteTransaction turn the dapp's Transaction JSON
// (`input.transaction.toJSON()`, not BCS — see ADR-023) into BCS with the
// bundled `@mysten/sui` `Transaction.build()` (ADR-032), backed by
// `makeCoreClient`'s adapter over native's read-only lookups. Native
// re-decodes and validates the result before any prompt.
(function () {
    'use strict';

    if (!window.__reefr || !window.__reefrWalletStandard || !window.__reefrLoadSuiSDK) {
        return;
    }

    var NAMESPACE = 'sui';
    var CHAINS = ['sui:mainnet', 'sui:testnet'];
    var FEATURES = [
        'standard:connect',
        'standard:disconnect',
        'standard:events',
        'sui:signPersonalMessage',
        'sui:signTransaction',
        'sui:signAndExecuteTransaction',
    ];

    var base64ToBytes = window.__reefrWalletStandard.base64ToBytes;
    var bytesToBase58 = window.__reefrWalletStandard.bytesToBase58;
    var bytesToBase64 = window.__reefrWalletStandard.bytesToBase64;

    // MARK: - Transaction building

    function normalizeAddress(address) {
        return '0x' + address.replace(/^0x/i, '').toLowerCase().padStart(64, '0');
    }

    // Native returns digests as base64; the SDK wants base58.
    function objectRef(object) {
        return { objectId: object.objectId, version: object.version, digest: bytesToBase58(base64ToBytes(object.digest)) };
    }

    function ownerFromNative(owner) {
        switch (owner.kind) {
            case 'address': return { $kind: 'AddressOwner', AddressOwner: owner.address };
            case 'immutable': return { $kind: 'Immutable', Immutable: true };
            case 'object': return { $kind: 'ObjectOwner', ObjectOwner: owner.address };
            case 'shared': return { $kind: 'Shared', Shared: { initialSharedVersion: owner.initialSharedVersion } };
            default: throw new Error('unsupported object owner kind: ' + owner.kind);
        }
    }

    function typeBodyFromNative(type) {
        switch (type.kind) {
            case 'datatype':
                return { $kind: 'datatype', datatype: { typeName: type.typeName, typeParameters: type.typeParameters.map(typeBodyFromNative) } };
            case 'typeParameter':
                return { $kind: 'typeParameter', index: type.index };
            case 'unsupported':
                return { $kind: 'unknown' };
            case 'vector':
                return { $kind: 'vector', vector: typeBodyFromNative(type.elementType) };
            default:
                return { $kind: type.kind };
        }
    }

    // The `client.core` subset `Transaction.build()`'s resolver calls, over
    // native lookups scoped to the connected `address`. Native gas is paid
    // from coin objects only (no address balances, coin reservations or
    // `ValidDuring` expirations), so `getBalance` reports no address
    // balance and `buildTransactionBytes` pins `expiration: None`.
    function makeCoreClient(address) {
        var account = { address: address };

        function request(method, params) {
            params.account = account;
            return window.__reefr.request(NAMESPACE, method, params);
        }

        var core = {
            resolveTransactionPlugin: function () {
                return window.__reefrLoadSuiSDK().coreClientResolveTransactionPlugin;
            },
            getBalance: function () {
                return Promise.resolve({ balance: { addressBalance: '0' } });
            },
            getChainIdentifier: function () {
                return Promise.resolve({ chainIdentifier: null });
            },
            getCurrentSystemState: function () {
                return request('getReferenceGasPrice', {}).then(function (result) {
                    return { systemState: { epoch: null, referenceGasPrice: result.price } };
                });
            },
            getMoveFunction: function (options) {
                var params = { package: options.packageId, module: options.moduleName, function: options.name };

                return request('getMoveFunction', params).then(function (result) {
                    return {
                        function: {
                            parameters: result.parameters.map(function (parameter) {
                                var reference = parameter.reference === 'none' ? null : parameter.reference;
                                return { reference: reference, body: typeBodyFromNative(parameter.type) };
                            }),
                        },
                    };
                });
            },
            // Aligned with `objectIds`, an `Error` for each missing object.
            getObjects: function (options) {
                return request('getObjects', { objectIds: options.objectIds }).then(function (result) {
                    var byId = {};

                    result.objects.forEach(function (object) {
                        byId[normalizeAddress(object.objectId)] = object;
                    });

                    return {
                        objects: options.objectIds.map(function (id) {
                            var object = byId[normalizeAddress(id)];

                            if (!object) {
                                return new Error('object not found: ' + id);
                            }

                            var ref = objectRef(object);
                            ref.owner = ownerFromNative(object.owner);
                            return ref;
                        }),
                    };
                });
            },
            listCoins: function (options) {
                return request('getCoins', { coinType: options.coinType }).then(function (result) {
                    return {
                        objects: result.coins.map(function (coin) {
                            var ref = objectRef(coin);
                            ref.balance = coin.balance;
                            return ref;
                        }),
                        hasNextPage: false,
                        cursor: null,
                    };
                });
            },
            simulateTransaction: function (options) {
                return request('simulateTransaction', { transactionBytes: bytesToBase64(options.transaction) }).then(function (cost) {
                    var gasUsed = {
                        computationCost: cost.computationCost,
                        storageCost: cost.storageCost,
                        storageRebate: cost.storageRebate,
                        nonRefundableStorageFee: '0',
                    };

                    return { $kind: 'Transaction', Transaction: { effects: { gasUsed: gasUsed } } };
                });
            },
        };

        return { core: core };
    }

    // Early, readable errors for what native would reject anyway.
    function validate(data, address) {
        if (data.sender && normalizeAddress(data.sender) !== normalizeAddress(address)) {
            throw new Error('transaction sender does not match the connected account');
        }

        if (data.gasData && data.gasData.owner && normalizeAddress(data.gasData.owner) !== normalizeAddress(address)) {
            throw new Error('sponsored transactions are not supported');
        }

        if (data.expiration && !data.expiration.None) {
            throw new Error('a transaction expiration is not supported');
        }
    }

    // `input.transaction` resolved into base64 BCS `TransactionData` for
    // native's `transactionBytes`.
    function buildTransactionBytes(input) {
        var address = input.account.address;

        return Promise.resolve(input.transaction.toJSON())
            .then(function (json) {
                validate(JSON.parse(json), address);

                var transaction = window.__reefrLoadSuiSDK().Transaction.from(json);
                transaction.setSenderIfNotSet(address);
                transaction.setExpiration({ None: true });
                return transaction.build({ client: makeCoreClient(address) });
            })
            .then(bytesToBase64);
    }

    // MARK: - Wallet

    var accounts = [];
    var changeListeners = [];

    function accountFromJSON(json) {
        return Object.freeze({
            address: json.address,
            publicKey: base64ToBytes(json.publicKey),
            chains: [json.chain],
            features: FEATURES,
        });
    }

    function notifyChange() {
        changeListeners.slice().forEach(function (listener) {
            try {
                listener({ accounts: accounts });
            } catch (error) {
                // A listener throwing shouldn't break delivery to the rest.
            }
        });
    }

    // Native's own "change" event carries no account payload when
    // something actually changed for a *permitted* origin (building a
    // full WalletAccount needs an async call `sessionDidChange` can't
    // make), so refetch via `connect` in that case — safe to call
    // repeatedly, since an already-permitted origin's `connect` never
    // re-prompts.
    function refreshAccounts() {
        return window.__reefr.request(NAMESPACE, 'connect', {}).then(function (result) {
            accounts = (result.accounts || []).map(accountFromJSON);
            return accounts;
        });
    }

    // An explicit `{accounts: []}` payload means the origin isn't
    // permitted (or no account is selected) — handle it locally. Calling
    // `connect` here would prompt for approval the dapp never requested
    // (e.g. just because the user switched the browser's Sui account
    // picker while this origin was never connected).
    window.__reefr.on(NAMESPACE, 'change', function (payload) {
        if (payload && Array.isArray(payload.accounts)) {
            accounts = payload.accounts.map(accountFromJSON);
            notifyChange();
            return;
        }
        refreshAccounts().then(notifyChange);
    });

    var wallet = {
        version: '1.0.0',
        name: 'Reefr Wallet',
        icon: window.__reefr.icon,
        chains: CHAINS,
        get accounts() {
            return accounts;
        },
        features: {
            'standard:connect': {
                version: '1.0.0',
                connect: function () {
                    return refreshAccounts().then(function (result) {
                        return { accounts: result };
                    });
                },
            },
            'standard:disconnect': {
                version: '1.0.0',
                disconnect: function () {
                    return window.__reefr.request(NAMESPACE, 'disconnect', {}).then(function () {
                        accounts = [];
                    });
                },
            },
            'standard:events': {
                version: '1.0.0',
                on: function (event, listener) {
                    if (event !== 'change') {
                        return function () {};
                    }
                    changeListeners.push(listener);
                    return function () {
                        var index = changeListeners.indexOf(listener);
                        if (index !== -1) {
                            changeListeners.splice(index, 1);
                        }
                    };
                },
            },
            'sui:signPersonalMessage': {
                version: '1.1.0',
                signPersonalMessage: function (input) {
                    return window.__reefr
                        .request(NAMESPACE, 'signPersonalMessage', {
                            message: bytesToBase64(input.message),
                            account: { address: input.account.address },
                        })
                        .then(function (result) {
                            return { bytes: result.bytes, signature: result.signature };
                        });
                },
            },
            'sui:signTransaction': {
                version: '2.0.0',
                signTransaction: function (input) {
                    return buildTransactionBytes(input).then(function (transactionBytesBase64) {
                        return window.__reefr
                            .request(NAMESPACE, 'signTransaction', {
                                transactionBytes: transactionBytesBase64,
                                account: { address: input.account.address },
                                chain: input.chain,
                            })
                            .then(function (result) {
                                return { bytes: result.bytes, signature: result.signature };
                            });
                    });
                },
            },
            'sui:signAndExecuteTransaction': {
                version: '2.0.0',
                signAndExecuteTransaction: function (input) {
                    return buildTransactionBytes(input).then(function (transactionBytesBase64) {
                        return window.__reefr
                            .request(NAMESPACE, 'signAndExecuteTransaction', {
                                transactionBytes: transactionBytesBase64,
                                account: { address: input.account.address },
                                chain: input.chain,
                            })
                            .then(function (result) {
                                return {
                                    bytes: result.bytes,
                                    signature: result.signature,
                                    digest: result.digest,
                                    effects: result.effects,
                                };
                            });
                    });
                },
            },
        },
    };

    window.__reefrWalletStandard.registerWallet(wallet);
})();
