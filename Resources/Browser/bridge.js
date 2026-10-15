// bridge.js — chain-agnostic transport + event bus injected into every
// browser page before any other script. Defines a frozen, non-enumerable
// `window.__reefr` that every per-chain provider script (providers/*.js)
// talks through, so the bridge/session/approval machinery on the native
// side never needs to know anything chain-specific.
(function () {
    'use strict';

    if (window.__reefr) {
        return;
    }

    var listeners = {}; // namespace -> event -> [fn, ...]

    function request(namespace, method, params) {
        return new Promise(function (resolve, reject) {
            window.webkit.messageHandlers.reefr
                .postMessage({ namespace: namespace, method: method, params: params === undefined ? [] : params })
                .then(
                    function (response) {
                        if (response && response.ok) {
                            resolve(response.value);
                            return;
                        }
                        var wireError = (response && response.error) || { code: -32603, message: 'Internal error' };
                        var error = new Error(wireError.message);
                        error.code = wireError.code;
                        reject(error);
                    },
                    function (nativeError) {
                        reject(nativeError);
                    }
                );
        });
    }

    function on(namespace, event, fn) {
        listeners[namespace] = listeners[namespace] || {};
        listeners[namespace][event] = listeners[namespace][event] || [];
        listeners[namespace][event].push(fn);
    }

    function removeListener(namespace, event, fn) {
        var fns = listeners[namespace] && listeners[namespace][event];

        if (!fns) {
            return;
        }

        var index = fns.indexOf(fn);

        if (index !== -1) {
            fns.splice(index, 1);
        }
    }

    // Called by the native side (`DappBridge.emit`) to push an event —
    // `accountsChanged`, `chainChanged`, `disconnect`, ... — into the page.
    function _emit(namespace, event, payload) {
        var fns = listeners[namespace] && listeners[namespace][event];

        if (!fns) {
            return;
        }

        fns.slice().forEach(function (fn) {
            try {
                fn(payload);
            } catch (error) {
                // A listener throwing shouldn't break delivery to the rest.
            }
        });
    }

    // Wallet icon announced to dapps (EIP-6963, TIP-6963, Wallet Standard).
    // DappScripts.swift replaces the placeholder with dapp-icon.svg as a
    // `data:` URI, which those standards require (the page can't read
    // the app bundle itself).
    var ICON = '__REEFR_ICON__';

    var reefr = {
        icon: ICON,
        request: request,
        on: on,
        removeListener: removeListener,
        _emit: _emit,
    };

    Object.defineProperty(window, '__reefr', {
        value: Object.freeze(reefr),
        writable: false,
        configurable: false,
        enumerable: false,
    });
})();
