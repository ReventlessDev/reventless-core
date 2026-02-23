# Jest `__mocks__` folder: stubbing `@npmcli/arborist` and `spdx-*`

## Affected packages

`reventless-in-memory`, `reventless-example-aggregate`

## Symptom

Running Jest in ESM mode (`NODE_OPTIONS='--experimental-vm-modules'`) fails when
importing any module that transitively depends on `@pulumi/pulumi`:

```
Cannot find module '@npmcli/arborist' from '...'
```

or cascading `require()` errors from deep inside `@npmcli/arborist`'s internals.

## Root cause

`@pulumi/pulumi` ships a CLI (`pulumi-language-nodejs`) that uses
`@npmcli/arborist` — a Node.js package manager internals library — to inspect
the dependency tree at runtime. The dependency is only needed for the CLI, not
for the Pulumi SDK that tests actually exercise.

However, because it appears in `@pulumi/pulumi`'s `dependencies`, Jest's module
resolver follows the import graph and tries to load it. `@npmcli/arborist` in
turn pulls in `spdx-license-ids`, `spdx-exceptions` and other packages that
either:

- lack an ESM-compatible entry point, or
- use dynamic `require()` calls that break under `--experimental-vm-modules`.

None of these modules are used at test runtime; they are dead code paths from
the Pulumi CLI that never execute during unit or E2E tests.

## Fix

Two complementary entries in each package's Jest `moduleNameMapper`:

### 1. Stub `@npmcli/arborist` with an empty module

```json
"moduleNameMapper": {
  "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js"
}
```

`__mocks__/emptyModule.js` (identical in both packages):
```js
// Empty stub module for Jest — prevents deep transitive requires from @pulumi/pulumi internals
module.exports = {};
```

Returning an empty object is safe because no code path in the tests ever calls
any `@npmcli/arborist` API.

### 2. Redirect `spdx-*` packages to their JSON files

```json
"^spdx-license-ids$": "<rootDir>/../../node_modules/spdx-license-ids/index.json",
"^spdx-license-ids/deprecated$": "<rootDir>/../../node_modules/spdx-license-ids/deprecated.json",
"^spdx-exceptions$": "<rootDir>/../../node_modules/spdx-exceptions/index.json"
```

These packages expose pure JSON data. Jest can load JSON files natively, so
pointing the mapper straight at the JSON files bypasses the non-ESM wrapper
scripts entirely.

## Why `__mocks__/emptyModule.js` instead of an inline stub

Jest's `moduleNameMapper` values must be file paths. Using a file in
`__mocks__/` keeps the stub under version control, visible to reviewers, and
reusable across any number of `moduleNameMapper` entries in the same package.
The file is intentionally minimal — a comment explaining its purpose and
`module.exports = {}`.

## Adding this to a new package

Copy `__mocks__/emptyModule.js` from an existing package and add the four
`moduleNameMapper` entries to the new package's Jest config in `package.json`.
No other changes are needed.
