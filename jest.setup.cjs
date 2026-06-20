const { webcrypto } = require("node:crypto");

if (typeof globalThis.crypto === "undefined") {
  globalThis.crypto = webcrypto;
}

// Jest's experimental-vm-modules sandbox does not expose every Node global.
// The AWS SDK v3 error-response deserializer calls structuredClone (e.g. when
// surfacing a DynamoDB TransactionCanceledException); without this polyfill the
// real error is masked by "structuredClone is not defined". Mirrors the crypto
// polyfill above. v8 structured-clone gives faithful deep copies of the plain
// objects the SDK clones.
if (typeof globalThis.structuredClone === "undefined") {
  const v8 = require("node:v8");
  globalThis.structuredClone = (value) =>
    value === undefined ? undefined : v8.deserialize(v8.serialize(value));
}
