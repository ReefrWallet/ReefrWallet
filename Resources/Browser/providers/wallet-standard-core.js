// wallet-standard-core.js — chain-agnostic Wallet Standard registration
// helper + byte-encoding helpers (base64, base58, hex, UTF-8) and a UUIDv4
// generator, shared by every providers/*.js script. Injected
// unconditionally alongside bridge.js (see DappScripts.swift), before any
// provider script.
(function () {
    'use strict';

    if (window.__reefrWalletStandard) {
        return;
    }

    // Mirrors @wallet-standard/wallet's own `registerWallet`: dispatch a
    // `wallet-standard:register-wallet` event immediately (for apps
    // already listening), and also listen for `wallet-standard:app-ready`
    // (for apps that start listening after this script runs) — this
    // combination registers the wallet correctly regardless of load
    // order between this script and the dapp's own Wallet Standard
    // client code.
    function registerWallet(wallet) {
        function callback(registerApi) {
            registerApi.register(wallet);
        }

        try {
            window.dispatchEvent(new CustomEvent('wallet-standard:register-wallet', { detail: callback }));
        } catch (error) {
            // A listener throwing shouldn't block registration.
        }

        try {
            window.addEventListener('wallet-standard:app-ready', function (event) {
                callback(event.detail);
            });
        } catch (error) {
            // Ditto.
        }
    }

    function bytesToBase64(bytes) {
        var binary = '';
        var chunkSize = 0x8000;

        for (var i = 0; i < bytes.length; i += chunkSize) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
        }

        return btoa(binary);
    }

    function base64ToBytes(base64) {
        var binary = atob(base64);
        var bytes = new Uint8Array(binary.length);

        for (var i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }

        return bytes;
    }

    // Lowercase, no `0x` prefix. Accepts any array-like of bytes.
    function bytesToHex(bytes) {
        var hex = '';

        for (var i = 0; i < bytes.length; i++) {
            hex += (bytes[i] & 0xff).toString(16).padStart(2, '0');
        }

        return hex;
    }

    var textEncoder = new TextEncoder();

    function utf8ToBytes(text) {
        return textEncoder.encode(text);
    }

    // EIP-6963/TIP-6963 provider-info `uuid`. Not `crypto.randomUUID()`:
    // that's missing on insecure (http:) pages.
    function uuidv4() {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
            var r = (Math.random() * 16) | 0;
            return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
        });
    }

    // Same alphabet/algorithm as WalletKit's own Base58.swift.
    var BASE58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

    function bytesToBase58(bytes) {
        if (bytes.length === 0) {
            return '';
        }

        var digits = [0];

        for (var i = 0; i < bytes.length; i++) {
            var carry = bytes[i];

            for (var j = 0; j < digits.length; j++) {
                var value = digits[j] * 256 + carry;
                digits[j] = value % 58;
                carry = Math.floor(value / 58);
            }

            while (carry > 0) {
                digits.push(carry % 58);
                carry = Math.floor(carry / 58);
            }
        }

        var leadingZeros = 0;
        for (var k = 0; k < bytes.length && bytes[k] === 0; k++) {
            leadingZeros++;
        }

        var result = '';
        for (var z = 0; z < leadingZeros; z++) {
            result += '1';
        }

        for (var d = digits.length - 1; d >= 0; d--) {
            result += BASE58_ALPHABET[digits[d]];
        }

        return result;
    }

    Object.defineProperty(window, '__reefrWalletStandard', {
        value: Object.freeze({
            registerWallet: registerWallet,
            base64ToBytes: base64ToBytes,
            bytesToBase58: bytesToBase58,
            bytesToBase64: bytesToBase64,
            bytesToHex: bytesToHex,
            utf8ToBytes: utf8ToBytes,
            uuidv4: uuidv4,
        }),
        writable: false,
        configurable: false,
        enumerable: false,
    });
})();
