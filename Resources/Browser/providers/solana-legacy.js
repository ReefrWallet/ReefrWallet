// providers/solana-legacy.js — legacy direct-injection `window.solana`
// provider (the Phantom-shaped API older Solana dapps and
// wallet-adapter's legacy fallback still look for), injected alongside
// the Wallet Standard provider (providers/solana.js). Both call into the
// same native SolanaDappProvider through the same window.__reefr
// transport and the same wire vocabulary (connect/disconnect/
// signMessage/signTransaction/signAndSendTransaction) — this script only
// adds a second, differently-shaped JS surface over it.
//
// `signTransaction`/`signAllTransactions` duck-type against
// `@solana/web3.js`'s `Transaction`/`VersionedTransaction` object shapes:
// the dapp's own bundled web3.js already put the right methods
// (`serializeMessage`, `addSignature`, ...) on the object it hands us, so
// this calls those rather than needing to import or reconstruct the
// class itself. This is a convenience layer only — every security-
// relevant check (fail-closed wire parsing, required-signer
// authorization, the RPC-reported broadcast signature) happens natively,
// exactly as for providers/solana.js; nothing here is trusted on its own.
//
// Deliberately honest about identity: `isReefr: true`, no `isPhantom`, no
// `window.phantom.solana` (see ADR-022's amendment) — matching
// providers/ethereum.js's own `isReefr`-not-`isMetaMask` precedent.
(function () {
    'use strict';

    if (!window.__reefr || !window.__reefrWalletStandard) {
        return;
    }
    if (window.solana) {
        return;
    }

    var NAMESPACE = 'solana';
    var bytesToBase64 = window.__reefrWalletStandard.bytesToBase64;
    var base64ToBytes = window.__reefrWalletStandard.base64ToBytes;
    var bytesToBase58 = window.__reefrWalletStandard.bytesToBase58;

    var publicKeyShim = null;
    var isConnected = false;
    var listeners = {};

    function on(event, listener) {
        listeners[event] = listeners[event] || [];
        listeners[event].push(listener);
    }

    function off(event, listener) {
        var list = listeners[event];

        if (!list) {
            return;
        }

        var index = list.indexOf(listener);

        if (index !== -1) {
            list.splice(index, 1);
        }
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

    function makePublicKeyShim(address, rawBytes) {
        return Object.freeze({
            toBase58: function () { return address; },
            toString: function () { return address; },
            toBytes: function () { return rawBytes; },
            toBuffer: function () { return rawBytes; }, // not a real Buffer — a Uint8Array duck-type
            toJSON: function () { return address; },
            equals: function (other) {
                return !!other && typeof other.toBase58 === 'function' && other.toBase58() === address;
            },
        });
    }

    function setConnected(accountJSON) {
        publicKeyShim = makePublicKeyShim(accountJSON.address, base64ToBytes(accountJSON.publicKey));
        isConnected = true;
        emit('connect', publicKeyShim);
    }

    function setDisconnected() {
        publicKeyShim = null;
        isConnected = false;
        emit('disconnect');
    }

    // Native's own "change" event (also consumed independently by
    // providers/solana.js — bridge.js supports multiple listeners per
    // namespace/event) carries the complete current account list;
    // translate it into the three legacy events by diffing against the
    // previous local state.
    window.__reefr.on(NAMESPACE, 'change', function (payload) {
        var accounts = (payload && payload.accounts) || [];
        var account = accounts[0];

        if (!account) {
            if (isConnected) {
                setDisconnected();
            }

            return;
        }

        if (!isConnected) {
            setConnected(account);
            return;
        }

        if (publicKeyShim.toBase58() !== account.address) {
            publicKeyShim = makePublicKeyShim(account.address, base64ToBytes(account.publicKey));
            emit('accountChanged', publicKeyShim);
        }
    });

    function requireConnected() {
        if (!isConnected || !publicKeyShim) {
            throw new Error('Reefr Wallet: not connected');
        }
    }

    function connect(options) {
        var onlyIfTrusted = !!(options && options.onlyIfTrusted);

        return window.__reefr.request(NAMESPACE, 'connect', { onlyIfTrusted: onlyIfTrusted }).then(function (result) {
            var account = (result.accounts || [])[0];

            if (!account) {
                throw new Error('Reefr Wallet: no Solana account available');
            }

            setConnected(account);
            return { publicKey: publicKeyShim };
        });
    }

    function disconnect() {
        return window.__reefr.request(NAMESPACE, 'disconnect', {}).then(function () {
            setDisconnected();
        });
    }

    function signMessage(message, display) {
        return Promise.resolve().then(function () {
            requireConnected();

            return window.__reefr
                .request(NAMESPACE, 'signMessage', {
                    message: bytesToBase64(message),
                    account: { address: publicKeyShim.toBase58() },
                })
                .then(function (result) {
                    return { signature: base64ToBytes(result.signature), publicKey: publicKeyShim };
                });
        });
    }

    // --- compact-u16 helpers for assembling/reading the full wire
    // transaction locally (native expects compact-u16(signatureCount) ||
    // signatures || message, not bare message bytes) ---

    function encodeShortVec(value) {
        var bytes = [];
        var remaining = value;

        while (true) {
            var byte = remaining & 0x7f;
            remaining = remaining >>> 7;

            if (remaining === 0) {
                bytes.push(byte);
                break;
            }

            bytes.push(byte | 0x80);
        }

        return bytes;
    }

    function decodeShortVecLength(bytes) {
        var offset = 0;

        while (true) {
            var byte = bytes[offset];
            offset += 1;

            if ((byte & 0x80) === 0) {
                break;
            }
        }

        return offset;
    }

    function concatBytes(parts) {
        var length = parts.reduce(function (sum, part) { return sum + part.length; }, 0);
        var result = new Uint8Array(length);
        var offset = 0;

        parts.forEach(function (part) {
            result.set(part, offset);
            offset += part.length;
        });

        return result;
    }

    var ZERO_SIGNATURE = new Uint8Array(64);

    // Duck-types `transaction` as a legacy `Transaction` or a
    // `VersionedTransaction` and extracts enough to build the full wire
    // bytes native expects: the bare message bytes, every existing
    // signature slot (zero-filled where unsigned), and the index of our
    // own account's slot. Throws (fails closed, before any native call)
    // if the object's shape isn't recognized or our account isn't among
    // its signers — native's own required-signer check is the
    // authoritative guard either way.
    function describeTransaction(transaction, ourAddress) {
        if (transaction && transaction.message && typeof transaction.message.serialize === 'function') {
            var staticKeys = transaction.message.staticAccountKeys || [];
            var requiredCount = transaction.message.header
                ? transaction.message.header.numRequiredSignatures
                : (transaction.signatures || []).length;

            var versionedSlot = -1;

            for (var i = 0; i < requiredCount && i < staticKeys.length; i++) {
                var key = staticKeys[i];
                var keyAddress = typeof key.toBase58 === 'function' ? key.toBase58() : String(key);

                if (keyAddress === ourAddress) {
                    versionedSlot = i;
                    break;
                }
            }

            if (versionedSlot === -1) {
                throw new Error('Reefr Wallet: this account is not a required signer of this transaction');
            }

            var versionedSignatures = (transaction.signatures || []).map(function (signature) {
                return signature && signature.length === 64 ? signature : ZERO_SIGNATURE;
            });

            return {
                messageBytes: transaction.message.serialize(),
                signatures: versionedSignatures,
                slotIndex: versionedSlot,
                apply: function (signatureBytes) {
                    transaction.signatures[versionedSlot] = signatureBytes;
                    return transaction;
                },
            };
        }

        if (transaction && typeof transaction.serializeMessage === 'function') {
            var sigEntries = transaction.signatures || [];
            var legacySlot = -1;
            var matchingEntry = null;

            for (var j = 0; j < sigEntries.length; j++) {
                var entry = sigEntries[j];
                var entryAddress = entry.publicKey && typeof entry.publicKey.toBase58 === 'function'
                    ? entry.publicKey.toBase58()
                    : String(entry.publicKey);

                if (entryAddress === ourAddress) {
                    legacySlot = j;
                    matchingEntry = entry;
                    break;
                }
            }

            if (legacySlot === -1) {
                throw new Error('Reefr Wallet: this account is not a required signer of this transaction');
            }

            var legacySignatures = sigEntries.map(function (entry) {
                return entry.signature && entry.signature.length === 64 ? entry.signature : ZERO_SIGNATURE;
            });

            return {
                messageBytes: transaction.serializeMessage(),
                signatures: legacySignatures,
                slotIndex: legacySlot,
                apply: function (signatureBytes) {
                    transaction.addSignature(matchingEntry.publicKey, signatureBytes);
                    return transaction;
                },
            };
        }

        throw new Error('Reefr Wallet: unsupported transaction object (expected a Transaction or VersionedTransaction)');
    }

    function buildWireBytes(description) {
        var parts = [new Uint8Array(encodeShortVec(description.signatures.length))];
        description.signatures.forEach(function (signature) {
            parts.push(signature);
        });
        parts.push(description.messageBytes);
        return concatBytes(parts);
    }

    function extractSignatureAtSlot(wireBytes, slotIndex) {
        var prefixLength = decodeShortVecLength(wireBytes);
        var start = prefixLength + slotIndex * 64;
        return wireBytes.slice(start, start + 64);
    }

    function signOneTransaction(transaction) {
        return Promise.resolve().then(function () {
            requireConnected();
            var ourAddress = publicKeyShim.toBase58();
            var description = describeTransaction(transaction, ourAddress);
            var wireBytes = buildWireBytes(description);

            return window.__reefr
                .request(NAMESPACE, 'signTransaction', {
                    transaction: bytesToBase64(wireBytes),
                    account: { address: ourAddress },
                })
                .then(function (result) {
                    var signedWireBytes = base64ToBytes(result.signedTransaction);
                    var ourSignature = extractSignatureAtSlot(signedWireBytes, description.slotIndex);
                    return description.apply(ourSignature);
                });
        });
    }

    function signTransaction(transaction) {
        return signOneTransaction(transaction);
    }

    // Sequential, not Promise.all: each call can trigger its own approval
    // prompt, and native serializes approvals per session — processing in
    // order keeps prompts appearing in the same order the dapp passed
    // transactions in.
    function signAllTransactions(transactions) {
        var results = [];

        return transactions
            .reduce(function (chain, transaction) {
                return chain.then(function () {
                    return signOneTransaction(transaction).then(function (signed) {
                        results.push(signed);
                    });
                });
            }, Promise.resolve())
            .then(function () {
                return results;
            });
    }

    function signAndSendTransaction(transaction, options) {
        return Promise.resolve().then(function () {
            requireConnected();
            var ourAddress = publicKeyShim.toBase58();
            var description = describeTransaction(transaction, ourAddress);
            var wireBytes = buildWireBytes(description);

            return window.__reefr
                .request(NAMESPACE, 'signAndSendTransaction', {
                    transaction: bytesToBase64(wireBytes),
                    account: { address: ourAddress },
                    options: options || {},
                })
                .then(function (result) {
                    return { signature: bytesToBase58(base64ToBytes(result.signature)) };
                });
        });
    }

    var provider = {
        isReefr: true,
        get isConnected() { return isConnected; },
        get publicKey() { return publicKeyShim; },
        connect: connect,
        disconnect: disconnect,
        signMessage: signMessage,
        signTransaction: signTransaction,
        signAllTransactions: signAllTransactions,
        signAndSendTransaction: signAndSendTransaction,
        on: on,
        off: off,
        removeListener: off,
    };

    window.solana = provider;
})();
