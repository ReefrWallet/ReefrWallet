// What providers/sui.js gets from `window.__reefrLoadSuiSDK()`.
export { Transaction } from '@mysten/sui/transactions';

// The SDK's own resolver for clients without server-side resolution (as its
// JSON-RPC client uses). Not in the package's exports map, hence the path.
export { coreClientResolveTransactionPlugin } from './node_modules/@mysten/sui/dist/client/core-resolver.mjs';
