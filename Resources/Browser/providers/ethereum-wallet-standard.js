// providers/ethereum-wallet-standard.js — an ADDITIVE Wallet Standard
// registration for Ethereum, alongside (not replacing) window.ethereum/
// EIP-6963 in providers/ethereum.js. Registers a second Wallet Standard
// `Wallet` object for the same 'ethereum' namespace, so a dapp that only
// discovers wallets via Wallet Standard (rather than EIP-6963) can still
// find this wallet.
//
// Generic Wallet Standard defines no EVM signing/transacting feature
// comparable to EIP-1193 (unlike Sui, which has official sui:* features)
// — this script is deliberately discovery-only (standard:connect/
// standard:events; standard:disconnect is client-side-only, since
// EIP-1193 has no wallet-side revocation to call into). window.ethereum/
// EIP-6963 (providers/ethereum.js) remains the only full-featured EVM
// surface; this file exists purely for Wallet-Standard-aware connection
// UIs' discoverability.
(function () {
    'use strict';

    if (!window.__reefr || !window.__reefrWalletStandard) {
        return;
    }

    var NAMESPACE = 'ethereum';
    var chainId = null; // e.g. "eip155:1"
    var accounts = [];
    var changeListeners = [];

    function accountFromAddress(address) {
        return Object.freeze({
            address: address,
            publicKey: new Uint8Array(0), // not derivable from an EVM address alone; EIP-6963/window.ethereum is the full-featured surface.
            chains: chainId ? [chainId] : [],
            features: ['standard:connect', 'standard:disconnect', 'standard:events'],
        });
    }

    function notifyChange() {
        changeListeners.slice().forEach(function (listener) {
            try {
                listener({ accounts: accounts, chains: chainId ? [chainId] : [] });
            } catch (error) {
                // A listener throwing shouldn't break delivery to the rest.
            }
        });
    }

    function refreshChainId() {
        return window.__reefr.request(NAMESPACE, 'eth_chainId', []).then(function (hexChainId) {
            var decimalChainId = parseInt(hexChainId, 16);
            chainId = 'eip155:' + decimalChainId;
            return chainId;
        });
    }

    window.__reefr.on(NAMESPACE, 'accountsChanged', function (addresses) {
        accounts = (Array.isArray(addresses) ? addresses : []).map(accountFromAddress);
        notifyChange();
    });

    window.__reefr.on(NAMESPACE, 'chainChanged', function () {
        refreshChainId().then(function () {
            accounts = accounts.map(function (account) {
                return accountFromAddress(account.address);
            });
            notifyChange();
        });
    });

    window.__reefr.on(NAMESPACE, 'disconnect', function () {
        accounts = [];
        notifyChange();
    });

    var wallet = {
        version: '1.0.0',
        name: 'Reefr Wallet',
        icon: window.__reefr.icon,
        get chains() {
            return chainId ? [chainId] : [];
        },
        get accounts() {
            return accounts;
        },
        features: {
            'standard:connect': {
                version: '1.0.0',
                connect: function () {
                    return refreshChainId().then(function () {
                        return window.__reefr.request(NAMESPACE, 'eth_requestAccounts', []);
                    }).then(function (addresses) {
                        accounts = (addresses || []).map(accountFromAddress);
                        return { accounts: accounts };
                    });
                },
            },
            'standard:disconnect': {
                version: '1.0.0',
                disconnect: function () {
                    // EIP-1193 has no wallet-side disconnect concept to
                    // call into — this only clears this script's own
                    // local state.
                    accounts = [];
                    return Promise.resolve();
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
        },
    };

    window.__reefrWalletStandard.registerWallet(wallet);
})();
