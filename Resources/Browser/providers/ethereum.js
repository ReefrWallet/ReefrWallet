// providers/ethereum.js — EIP-1193 (`window.ethereum`) and EIP-6963
// provider, injected after bridge.js and wallet-standard-core.js. Every
// request/event routes through `window.__reefr` under the `ethereum`
// namespace.
(function () {
    'use strict';

    if (!window.__reefr || !window.__reefrWalletStandard) {
        return;
    }

    var NAMESPACE = 'ethereum';
    var chainId = null;
    var selectedAddress = null;

    function request(args) {
        var method = args && args.method;
        var params = args && args.params;

        return window.__reefr.request(NAMESPACE, method, params).then(function (result) {
            if (method === 'eth_chainId' && typeof result === 'string') {
                chainId = result;
            }

            if ((method === 'eth_requestAccounts' || method === 'eth_accounts') && Array.isArray(result)) {
                selectedAddress = result.length > 0 ? result[0] : null;
            }

            return result;
        });
    }

    // Legacy convenience methods some older dapps still call directly.
    function enable() {
        return request({ method: 'eth_requestAccounts' });
    }

    function send(methodOrPayload, paramsOrCallback) {
        if (typeof methodOrPayload === 'string') {
            return request({ method: methodOrPayload, params: paramsOrCallback });
        }

        sendAsync(methodOrPayload, paramsOrCallback);
        return undefined;
    }

    function sendAsync(payload, callback) {
        request({ method: payload.method, params: payload.params }).then(
            function (result) {
                callback(null, { id: payload.id, jsonrpc: '2.0', result: result });
            },
            function (error) {
                callback(error, null);
            }
        );
    }

    var provider = {
        isReefr: true,
        request: request,
        enable: enable,
        send: send,
        sendAsync: sendAsync,
        on: function (event, fn) {
            window.__reefr.on(NAMESPACE, event, fn);
        },
        removeListener: function (event, fn) {
            window.__reefr.removeListener(NAMESPACE, event, fn);
        },
    };

    Object.defineProperty(provider, 'chainId', { get: function () { return chainId; } });
    Object.defineProperty(provider, 'selectedAddress', { get: function () { return selectedAddress; } });

    window.__reefr.on(NAMESPACE, 'accountsChanged', function (accounts) {
        selectedAddress = Array.isArray(accounts) && accounts.length > 0 ? accounts[0] : null;
    });

    window.__reefr.on(NAMESPACE, 'chainChanged', function (newChainId) {
        chainId = newChainId;
    });

    window.__reefr.on(NAMESPACE, 'disconnect', function () {
        selectedAddress = null;
    });

    if (!window.ethereum) {
        window.ethereum = provider;
    }

    // EIP-6963: announce this provider so multi-wallet-aware dapps can
    // list it alongside any other injected provider, keyed by `rdns`.
    var providerInfo = Object.freeze({
        uuid: window.__reefrWalletStandard.uuidv4(), // EIP-6963: one UUIDv4 per provider session
        name: 'Reefr Wallet',
        icon: window.__reefr.icon,
        rdns: 'xyz.reefr.wallet',
    });

    function announceProvider() {
        window.dispatchEvent(
            new CustomEvent('eip6963:announceProvider', {
                detail: Object.freeze({ info: providerInfo, provider: provider }),
            })
        );
    }

    window.addEventListener('eip6963:requestProvider', announceProvider);
    announceProvider();
})();
