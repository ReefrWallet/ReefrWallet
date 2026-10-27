// providers/cardano.js — CIP-30 Cardano provider: `window.cardano.reefr`.
//
// Every call crosses the bridge as `request('cardano', <api name>, <positional
// args>)` with hex strings for CBOR/addresses. Native rejects with the wire
// envelope `{ code, info }` (or `{ maxSize }`); `bridge.js` surfaces it as an
// `Error` with `code` and `message` (= info) set, which this script turns
// into the plain CIP-30 error object for the invoked method. Identity stays
// honest: no spoofing of other wallets' names.
(function () {
    'use strict';

    if (!window.__reefr) {
        return;
    }

    var NAMESPACE = 'cardano';

    // Error class by method; the code is the fallback when native sent none.
    var ERROR_FALLBACK_CODES = { APIError: -2, DataSignError: 1, TxSendError: 2, TxSignError: 1 };
    var ERROR_CLASS = { signData: 'DataSignError', signTx: 'TxSignError', submitTx: 'TxSendError' };

    function toCIP30Error(method, error) {
        if (error && typeof error.maxSize === 'number') {
            return { maxSize: error.maxSize };
        }

        var kind = ERROR_CLASS[method] || 'APIError';
        var info = error && typeof error.info === 'string' ? error.info : error && error.message;

        return {
            code: error && typeof error.code === 'number' ? error.code : ERROR_FALLBACK_CODES[kind],
            info: typeof info === 'string' ? info : String(error),
        };
    }

    function call(method, params) {
        return window.__reefr.request(NAMESPACE, method, params).catch(function (error) {
            throw toCIP30Error(method, error);
        });
    }

    function orNull(value) {
        return value === undefined ? null : value;
    }

    var api = Object.freeze({
        getBalance: function () {
            return call('getBalance', []);
        },
        getChangeAddress: function () {
            return call('getChangeAddress', []);
        },
        getExtensions: function () {
            return Promise.resolve([]);
        },
        getNetworkId: function () {
            return call('getNetworkId', []);
        },
        getRewardAddresses: function () {
            return call('getRewardAddresses', []);
        },
        getUnusedAddresses: function () {
            return call('getUnusedAddresses', []);
        },
        getUsedAddresses: function (paginate) {
            return call('getUsedAddresses', [orNull(paginate)]);
        },
        getUtxos: function (amount, paginate) {
            return call('getUtxos', [orNull(amount), orNull(paginate)]);
        },
        signData: function (address, payload) {
            return call('signData', [address, payload]);
        },
        signTx: function (tx, partialSign) {
            return call('signTx', [tx, partialSign === true]);
        },
        submitTx: function (tx) {
            return call('submitTx', [tx]);
        },
    });

    var reefr = Object.freeze({
        name: 'Reefr Wallet',
        icon: window.__reefr.icon,
        apiVersion: '1',
        supportedExtensions: Object.freeze([]),
        // Requested extensions are ignored: none are supported.
        enable: function () {
            return call('enable', []).then(function () {
                return api;
            });
        },
        isEnabled: function () {
            return call('isEnabled', []);
        },
    });

    try {
        window.cardano = window.cardano || {};

        if (!window.cardano.reefr) {
            Object.defineProperty(window.cardano, 'reefr', { value: reefr, enumerable: true });
        }
    } catch (error) {
        // `window.cardano` isn't extensible; nothing to register on.
    }
})();
