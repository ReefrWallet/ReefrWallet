// Aptos Wallet Standard (AIP-62) provider, injected after bridge.js and
// wallet-standard-core.js. Implements the required feature set (aptos:connect/
// disconnect/account/network/signMessage/signTransaction/onAccountChange/
// onNetworkChange) over `window.__reefr.request('aptos', ...)`.
//
// No Aptos SDK is bundled. Results are SDK-compatible stand-ins:
// addresses, public keys, and signatures are `Uint8Array`s (so the dapp's own
// `AccountAddress.from(...)` etc. accept them) with `toString()`,
// `toUint8Array()`, `bcsToBytes()`, and `serialize()` added. The SDK
// re-deserializes a wallet's authenticator from `bcsToBytes()`
// (`normalizeBundle`), so native's BCS bytes are all it needs.
//
// signTransaction is version 1.0.0 (a built `AnyRawTransaction`); the wallet
// adapter builds transactions itself for wallets without
// aptos:signAndSubmitTransaction. Fee-payer and multi-agent transactions are
// refused: their signing message differs from a plain RawTransaction's.
(function () {
    'use strict';

    if (!window.__reefr || !window.__reefrWalletStandard) {
        return;
    }

    var NAMESPACE = 'aptos';
    var CHAINS = ['aptos:mainnet', 'aptos:testnet'];
    var USER_REJECTED = 4001;

    var base64ToBytes = window.__reefrWalletStandard.base64ToBytes;
    var bytesToBase64 = window.__reefrWalletStandard.bytesToBase64;
    var bytesToHex = window.__reefrWalletStandard.bytesToHex;

    var accountInfo = null;
    var networkInfo = null;
    var accountListeners = [];
    var networkListeners = [];
    var changeListeners = [];

    // A Uint8Array that also answers the SDK's Serializable/Hex-like methods.
    function sdkBytes(raw, string, bcs) {
        var value = new Uint8Array(raw);

        var methods = {
            toString: function () { return string; },
            toStringLong: function () { return string; },
            toUint8Array: function () { return new Uint8Array(raw); },
            bcsToBytes: function () { return new Uint8Array(bcs); },
            serialize: function (serializer) { serializer.serializeFixedBytes(new Uint8Array(bcs)); },
        };

        Object.keys(methods).forEach(function (name) {
            Object.defineProperty(value, name, { value: methods[name], enumerable: false });
        });

        return value;
    }

    // An AccountAuthenticator stand-in: only its BCS form is ever read.
    function authenticator(bcs) {
        return {
            bcsToBytes: function () { return new Uint8Array(bcs); },
            serialize: function (serializer) { serializer.serializeFixedBytes(new Uint8Array(bcs)); },
        };
    }

    function accountFromJSON(json) {
        if (!json) {
            return null;
        }

        var address = base64ToBytes(json.address);
        var publicKey = base64ToBytes(json.publicKey);

        return Object.freeze({
            address: sdkBytes(address, json.addressString, address),
            publicKey: sdkBytes(publicKey, '0x' + bytesToHex(publicKey), base64ToBytes(json.publicKeyBcs)),
            ansName: undefined,
            chains: [json.chain],
            features: Object.keys(features),
        });
    }

    function approved(args) {
        return { status: 'Approved', args: args };
    }

    function rejectedOrThrow(error) {
        if (error && error.code === USER_REJECTED) {
            return { status: 'Rejected' };
        }

        throw error;
    }

    function request(method, params) {
        return window.__reefr.request(NAMESPACE, method, params || {});
    }

    function refresh() {
        return Promise.all([request('account'), request('network')]).then(function (results) {
            var nextAccount = accountFromJSON(results[0].account);
            var nextNetwork = results[1];

            var accountChanged = (accountInfo && accountInfo.address.toString()) !==
                (nextAccount && nextAccount.address.toString());

            var networkChanged = JSON.stringify(networkInfo) !== JSON.stringify(nextNetwork);
            accountInfo = nextAccount;
            networkInfo = nextNetwork;

            if (accountChanged) {
                accountListeners.slice().forEach(function (listener) { safely(listener, accountInfo); });
                changeListeners.slice().forEach(function (listener) { safely(listener, { accounts: accounts() }); });
            }

            if (networkChanged) {
                networkListeners.slice().forEach(function (listener) { safely(listener, networkInfo); });
            }
        });
    }

    function safely(listener, value) {
        try {
            listener(value);
        } catch (error) {
            // A listener throwing shouldn't break delivery to the rest.
        }
    }

    function accounts() {
        return accountInfo ? [accountInfo] : [];
    }

    window.__reefr.on(NAMESPACE, 'change', function (payload) {
        if (payload && payload.disconnected) {
            accountInfo = null;
            changeListeners.slice().forEach(function (listener) { safely(listener, { accounts: [] }); });
            return;
        }

        refresh().catch(function () {});
    });

    function connect() {
        return request('connect')
            .then(function (result) {
                accountInfo = accountFromJSON(result.account);
                networkInfo = result.network;
                return approved(accountInfo);
            })
            .catch(rejectedOrThrow);
    }

    function signMessage(input) {
        if (!input || typeof input.message !== 'string' || typeof input.nonce !== 'string') {
            return Promise.reject(new Error('signMessage expects {message: string, nonce: string}'));
        }

        return request('signMessage', {
            message: input.message,
            nonce: input.nonce,
            address: !!input.address,
            application: !!input.application,
            chainId: !!input.chainId,
            account: { address: accountInfo && accountInfo.address.toString() },
        }).then(function (result) {
            var signature = base64ToBytes(result.signature);
            var output = {
                fullMessage: result.fullMessage,
                message: result.message,
                nonce: result.nonce,
                prefix: 'APTOS',
                signature: sdkBytes(signature, '0x' + bytesToHex(signature), base64ToBytes(result.signatureBcs)),
            };
            if (result.address !== undefined) { output.address = result.address; }
            if (result.application !== undefined) { output.application = result.application; }
            if (result.chainId !== undefined) { output.chainId = result.chainId; }
            return approved(output);
        }).catch(rejectedOrThrow);
    }

    function signTransaction(transaction, asFeePayer) {
        if (!transaction || !transaction.rawTransaction || typeof transaction.rawTransaction.bcsToBytes !== 'function') {
            return Promise.reject(new Error('signTransaction expects a built transaction (version 1.0.0)'));
        }

        var secondary = transaction.secondarySignerAddresses;
        if (asFeePayer || transaction.feePayerAddress || (secondary && secondary.length)) {
            return Promise.reject(new Error('Fee-payer and multi-agent transactions are not supported'));
        }

        return request('signTransaction', {
            rawTransaction: bytesToBase64(transaction.rawTransaction.bcsToBytes()),
            account: { address: accountInfo && accountInfo.address.toString() },
        }).then(function (result) {
            return approved(authenticator(base64ToBytes(result.authenticator)));
        }).catch(rejectedOrThrow);
    }

    var features = {
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
        'aptos:connect': { version: '1.0.0', connect: connect },
        'aptos:disconnect': {
            version: '1.0.0',
            disconnect: function () {
                return request('disconnect').then(function () {
                    accountInfo = null;
                });
            },
        },
        'aptos:account': {
            version: '1.0.0',
            account: function () {
                return request('account').then(function (result) {
                    accountInfo = accountFromJSON(result.account);

                    if (!accountInfo) {
                        throw new Error('No Aptos account is connected.');
                    }

                    return accountInfo;
                });
            },
        },
        'aptos:network': {
            version: '1.0.0',
            network: function () {
                return request('network').then(function (result) {
                    networkInfo = result;
                    return result;
                });
            },
        },
        'aptos:signMessage': { version: '1.0.0', signMessage: signMessage },
        'aptos:signTransaction': { version: '1.0.0', signTransaction: signTransaction },
        'aptos:onAccountChange': {
            version: '1.0.0',
            onAccountChange: function (listener) {
                accountListeners = [listener];
                return Promise.resolve();
            },
        },
        'aptos:onNetworkChange': {
            version: '1.0.0',
            onNetworkChange: function (listener) {
                networkListeners = [listener];
                return Promise.resolve();
            },
        },
    };

    window.__reefrWalletStandard.registerWallet({
        version: '1.0.0',
        name: 'Reefr Wallet',
        icon: window.__reefr.icon,
        chains: CHAINS,
        get accounts() {
            return accounts();
        },
        features: features,
    });
})();
