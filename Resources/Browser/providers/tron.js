// providers/tron.js — TronLink-compatible Tron provider: `window.tronLink`
// (`ready`, `tronWeb`, `request({method: 'tron_requestAccounts'})`),
// `window.tronWeb`, and a TIP-1193 `window.tron` announced over TIP-6963 —
// what @tronweb3/tronwallet-adapters' TronLink adapter and older Tron dapps
// look for.
//
// TronWeb itself (vendor/tronweb.js) loads on the first `tronWeb` read.
// Its node HTTP goes through native (`nodeRequest`, so the TronGrid key
// never reaches the page) and its signing methods are replaced with native
// calls. This is a convenience layer only: every security check (strict
// `raw_data_hex` decoding, owner authorization, Trezor reproducibility)
// happens in TronDappProvider.
//
// Identity stays honest: `isReefr: true`, no `isTronLink`, and TIP-6963
// announces Reefr's own name. The legacy `window.postMessage` events carry
// `isTronLink: true` only because that's the envelope Tron dapps filter on.
(function () {
    'use strict';

    if (!window.__reefr || !window.__reefrWalletStandard || !window.__reefrLoadTronWeb || window.tronLink) {
        return;
    }

    var bytesToHex = window.__reefrWalletStandard.bytesToHex;
    var utf8ToBytes = window.__reefrWalletStandard.utf8ToBytes;

    var NAMESPACE = 'tron';
    var state = { account: null, chainId: '0x2b6653dc', host: 'https://api.trongrid.io' };
    var tronWeb = null;
    var nodeProvider = null;
    var listeners = {};

    function request(method, params) {
        return window.__reefr.request(NAMESPACE, method, params || {});
    }

    function rpcError(code, message) {
        var error = new Error(message);
        error.code = code;
        return error;
    }

    // --- TIP-1193 events ---

    function on(event, listener) {
        listeners[event] = listeners[event] || [];
        listeners[event].push(listener);
        return this;
    }

    function removeListener(event, listener) {
        var list = listeners[event] || [];
        var index = list.indexOf(listener);

        if (index !== -1) {
            list.splice(index, 1);
        }

        return this;
    }

    function emit(event, payload) {
        (listeners[event] || []).slice().forEach(function (listener) {
            try {
                listener(payload);
            } catch (error) {
                // A listener throwing shouldn't break delivery to the rest.
            }
        });
    }

    function postLegacy(action, data) {
        if (typeof window.postMessage !== 'function') {
            return;
        }

        var message = data === undefined ? { action: action } : { action: action, data: data };
        window.postMessage({ message: message, isTronLink: true }, '*');
    }

    // --- bytes ---

    function messageToHex(message) {
        if (typeof message === 'string') {
            return bytesToHex(utf8ToBytes(message));
        }

        if (message instanceof Uint8Array || Array.isArray(message)) {
            return bytesToHex(message);
        }

        throw new Error('Reefr Wallet: message must be a string or bytes');
    }

    // --- TronWeb ---

    function unsupported(name) {
        return function () {
            return Promise.reject(new Error('Reefr Wallet: ' + name + ' is not supported'));
        };
    }

    function signTransaction(transaction, privateKey, useTronHeader, multisig) {
        return Promise.resolve().then(function () {
            if (typeof transaction === 'string') {
                throw new Error('Reefr Wallet: signing hex strings is not supported, use signMessageV2');
            }

            if (!transaction || typeof transaction !== 'object' || typeof transaction.raw_data_hex !== 'string') {
                throw new Error('Invalid transaction provided');
            }

            if (multisig) {
                throw new Error('Reefr Wallet: multi-signature is not supported');
            }

            if (transaction.signature && transaction.signature.length) {
                throw new Error('Transaction is already signed');
            }

            return request('signTransaction', {
                transaction: { txID: transaction.txID, raw_data_hex: transaction.raw_data_hex },
            }).then(function (result) {
                transaction.signature = [result.signature];
                return transaction;
            });
        });
    }

    function signMessageV2(message) {
        return Promise.resolve().then(function () {
            return request('signMessage', { message: messageToHex(message) }).then(function (result) {
                return result.signature;
            });
        });
    }

    function makeTronWeb() {
        var module = window.__reefrLoadTronWeb();

        class NativeNodeProvider extends module.providers.HttpProvider {
            request(url, payload, method) {
                return request('nodeRequest', {
                    path: String(url),
                    method: String(method || 'get'),
                    payload: JSON.parse(JSON.stringify(payload || {})),
                });
            }
        }

        nodeProvider = new NativeNodeProvider(state.host);

        var instance = new module.TronWeb({
            fullNode: nodeProvider,
            solidityNode: nodeProvider,
            eventServer: nodeProvider,
        });

        instance.trx.sign = signTransaction;
        instance.trx.signTransaction = signTransaction;
        instance.trx.signMessage = signTransaction;
        instance.trx.signMessageV2 = signMessageV2;
        instance.trx.multiSign = unsupported('multiSign');
        instance.trx._signTypedData = unsupported('signTypedData');
        instance.trx.signTypedData = unsupported('signTypedData');
        return instance;
    }

    function syncTronWeb() {
        nodeProvider.host = state.host.replace(/\/+$/, '');

        if (state.account) {
            tronWeb.setAddress(state.account.address);
        } else {
            tronWeb.defaultAddress = { hex: false, base58: false };
        }

        tronWeb.ready = !!state.account;
    }

    function getTronWeb() {
        if (!tronWeb) {
            tronWeb = makeTronWeb();
            syncTronWeb();
        }

        return tronWeb;
    }

    // --- state ---

    function applyState(next) {
        var previous = state.account ? state.account.address : null;
        var previousChainId = state.chainId;

        state = {
            account: next.account === undefined ? state.account : next.account,
            chainId: next.chainId || state.chainId,
            host: next.host || state.host,
        };

        if (tronWeb) {
            syncTronWeb();
        }

        var current = state.account ? state.account.address : null;

        if (current !== previous) {
            emit('accountsChanged', current ? [current] : []);
            postLegacy('accountsChanged', { address: current || false });

            if (current && !previous) {
                emit('connect', { chainId: state.chainId });
                postLegacy('connect');
            } else if (!current) {
                emit('disconnect', rpcError(4900, 'Disconnected'));
                postLegacy('disconnect');
            }
        }

        if (state.chainId !== previousChainId) {
            emit('chainChanged', { chainId: state.chainId });
            postLegacy('setNode', {
                node: { fullNode: state.host, solidityNode: state.host, eventServer: state.host, chainId: state.chainId },
            });
        }
    }

    window.__reefr.on(NAMESPACE, 'change', function (payload) {
        applyState(payload || {});
    });

    function requestAccounts() {
        return request('connect', {}).then(function (account) {
            applyState({ account: account });
            getTronWeb();
            return account;
        });
    }

    // --- window.tron (TIP-1193) ---

    function switchChain(params) {
        var target = params && params[0] && params[0].chainId;
        if (target === state.chainId) {
            return Promise.resolve(null);
        }

        return Promise.reject(rpcError(4901, 'Switch Tron networks in Reefr Wallet\'s account picker.'));
    }

    var tron = {
        isReefr: true,
        get tronWeb() {
            return state.account ? getTronWeb() : false;
        },
        request: function (args) {
            var method = args && args.method;

            switch (method) {
            case 'eth_requestAccounts':
            case 'tron_requestAccounts':
                return requestAccounts().then(function (account) {
                    return [account.address];
                });
            case 'eth_accounts':
            case 'tron_accounts':
                return Promise.resolve(state.account ? [state.account.address] : []);
            case 'eth_chainId':
            case 'tron_chainId':
                return Promise.resolve(state.chainId);
            case 'wallet_switchEthereumChain':
                return switchChain(args.params);
            default:
                return Promise.reject(rpcError(4200, 'Reefr Wallet: unsupported method ' + method));
            }
        },
        on: on,
        removeListener: removeListener,
    };

    // --- window.tronLink (legacy TronLink) ---

    var tronLink = {
        isReefr: true,
        get ready() {
            return !!state.account;
        },
        get tronWeb() {
            return getTronWeb();
        },
        // TronLink resolves `{code, message}` rather than rejecting, and
        // `null` when no account is available.
        request: function (args) {
            if (!args || args.method !== 'tron_requestAccounts') {
                return tron.request(args);
            }

            return requestAccounts().then(
                function () {
                    return { code: 200, message: 'The site is already in the whitelist' };
                },
                function (error) {
                    if (error && error.code === 4001) {
                        return { code: 4001, message: 'User rejected' };
                    }
                    if (error && error.code === 4900) {
                        return null;
                    }
                    throw error;
                }
            );
        },
    };

    Object.defineProperty(window, 'tronLink', { value: tronLink, writable: false, configurable: false });
    Object.defineProperty(window, 'tronWeb', { get: getTronWeb, configurable: false });

    if (!window.tron) {
        Object.defineProperty(window, 'tron', { value: tron, writable: false, configurable: false });
    }

    // --- TIP-6963 ---

    var providerInfo = Object.freeze({
        uuid: window.__reefrWalletStandard.uuidv4(),
        name: 'Reefr Wallet',
        icon: window.__reefr.icon,
        rdns: 'xyz.reefr.wallet',
    });

    function announceProvider() {
        window.dispatchEvent(
            new CustomEvent('TIP6963:announceProvider', {
                detail: Object.freeze({ info: providerInfo, provider: tron }),
            })
        );
    }

    window.addEventListener('TIP6963:requestProvider', announceProvider);
    announceProvider();

    // --- initial state: network, then a silent reconnect if already trusted ---

    request('network', {})
        .then(function (network) {
            applyState(network || {});
            return request('connect', { onlyIfTrusted: true });
        })
        .then(
            function (account) {
                applyState({ account: account });
            },
            function () {
                // Not connected yet; the dapp asks via `tron_requestAccounts`.
            }
        );
})();
