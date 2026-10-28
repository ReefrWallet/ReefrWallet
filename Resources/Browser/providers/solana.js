// providers/solana.js — Solana Wallet Standard provider, injected after
// bridge.js and wallet-standard-core.js. Registers a Wallet Standard
// `Wallet` object (per @wallet-standard/base and @solana/wallet-standard's
// solana:* feature interfaces) whose features call back into native Swift
// through `window.__reefr.request('solana', method, params)` — the same
// transport providers/ethereum.js and providers/sui.js already use, just
// under the 'solana' namespace.
//
// Unlike providers/sui.js, native's own "change" event already carries the
// complete account list (a Solana address needs no signer construction to
// derive its public key), so this script replaces `accounts` directly from
// the event payload rather than re-fetching via `connect`.
//
// Every signing/sending feature is genuinely variadic per the Wallet
// Standard spec (`(...inputs) => Promise<Output[]>`): inputs are processed
// sequentially (not `Promise.all`), so native's serial approval queue never
// sees overlapping prompts, and outputs are returned in the same order,
// always as an array — even for a single input.
(function () {
    'use strict';

    if (!window.__reefr || !window.__reefrWalletStandard) {
        return;
    }

    var NAMESPACE = 'solana';
    var CHAINS = ['solana:mainnet', 'solana:devnet', 'solana:testnet'];
    var SUPPORTED_TRANSACTION_VERSIONS = ['legacy', 0];
    var FEATURES = [
        'standard:connect',
        'standard:disconnect',
        'standard:events',
        'solana:signMessage',
        'solana:signTransaction',
        'solana:signAndSendTransaction',
    ];

    var bytesToBase64 = window.__reefrWalletStandard.bytesToBase64;
    var base64ToBytes = window.__reefrWalletStandard.base64ToBytes;

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

    // Native's own "change" event already carries the full account list —
    // unlike providers/sui.js, no async re-fetch is needed to react to it.
    window.__reefr.on(NAMESPACE, 'change', function (payload) {
        var json = (payload && payload.accounts) || [];
        accounts = json.map(accountFromJSON);
        notifyChange();
    });

    // Runs `handler` over `inputs` one at a time, in order, collecting
    // results in the same order — the shared sequential-processing helper
    // every variadic feature below uses.
    function sequential(inputs, handler) {
        var results = [];

        return inputs
            .reduce(function (chain, input) {
                return chain.then(function () {
                    return handler(input).then(function (result) {
                        results.push(result);
                    });
                });
            }, Promise.resolve())
            .then(function () {
                return results;
            });
    }

    function signMessage(input) {
        return window.__reefr
            .request(NAMESPACE, 'signMessage', {
                message: bytesToBase64(input.message),
                account: { address: input.account.address },
            })
            .then(function (result) {
                return {
                    signedMessage: base64ToBytes(result.signedMessage),
                    signature: base64ToBytes(result.signature),
                };
            });
    }

    function signTransaction(input) {
        return window.__reefr
            .request(NAMESPACE, 'signTransaction', {
                transaction: bytesToBase64(input.transaction),
                account: { address: input.account.address },
                chain: input.chain,
            })
            .then(function (result) {
                return { signedTransaction: base64ToBytes(result.signedTransaction) };
            });
    }

    function signAndSendTransaction(input) {
        return window.__reefr
            .request(NAMESPACE, 'signAndSendTransaction', {
                transaction: bytesToBase64(input.transaction),
                account: { address: input.account.address },
                chain: input.chain,
                options: input.options,
            })
            .then(function (result) {
                return { signature: base64ToBytes(result.signature) };
            });
    }

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
                // A `silent` connect (wallet adapters' auto-connect on load) must
                // never prompt: it only succeeds if the site is already connected.
                connect: function (input) {
                    var params = { onlyIfTrusted: !!(input && input.silent) };

                    return window.__reefr.request(NAMESPACE, 'connect', params).then(function (result) {
                        accounts = (result.accounts || []).map(accountFromJSON);
                        return { accounts: accounts };
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
            'solana:signMessage': {
                version: '1.1.0',
                signMessage: function () {
                    return sequential(Array.prototype.slice.call(arguments), signMessage);
                },
            },
            'solana:signTransaction': {
                version: '1.0.0',
                supportedTransactionVersions: SUPPORTED_TRANSACTION_VERSIONS,
                signTransaction: function () {
                    return sequential(Array.prototype.slice.call(arguments), signTransaction);
                },
            },
            'solana:signAndSendTransaction': {
                version: '1.0.0',
                supportedTransactionVersions: SUPPORTED_TRANSACTION_VERSIONS,
                signAndSendTransaction: function () {
                    return sequential(Array.prototype.slice.call(arguments), signAndSendTransaction);
                },
            },
        },
    };

    window.__reefrWalletStandard.registerWallet(wallet);
})();
