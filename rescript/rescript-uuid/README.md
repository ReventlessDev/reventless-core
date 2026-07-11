[![npm](https://img.shields.io/npm/v/@reventlessdev/rescript-uuid.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/rescript-uuid)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/rescript-uuid

> ⚠️ **Alpha.** APIs can change without notice between releases.
> Pin exact versions and expect breaking changes.

ReScript bindings for [uuid](https://github.com/uuidjs/uuid) - RFC4122 UUID generation.

## Installation

1. Add `@reventlessdev/rescript-uuid` to your dependencies in `package.json`:
```json
{
  "dependencies": {
    "@reventlessdev/rescript-uuid": "^1.0.0",
    "uuid": "^9.0.0"
  }
}
```

2. Add `@reventlessdev/rescript-uuid` to `dependencies` in `rescript.json`:
```json
{
  "dependencies": [
    "@reventlessdev/rescript-uuid"
  ]
}
```

3. Install dependencies:
```bash
pnpm install
```

For general information see this monorepo's [readme](../../README.md).

## API

### `v1()` - Timestamp-based UUID

Generates a UUID v1 (timestamp-based).

```rescript
let id = Uuid.v1()
// => "2c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d"
```

### `v4()` - Random UUID

Generates a UUID v4 (random).

```rescript
let id = Uuid.v4()
// => "416ac246-e7ac-49ff-93b4-f7e94d997e6b"
```

### `v3(~name, ~namespace)` - Namespace UUID (MD5)

Generates a UUID v3 (namespace-based with MD5 hash).

```rescript
// Using predefined DNS namespace
let id = Uuid.v3(~name="hello.example.com", ~namespace=Uuid.Namespace.dns)
// => "9125a8dc-52ee-365b-a5aa-81b0b3681cf6"

// Using predefined URL namespace
let id = Uuid.v3(~name="http://example.com/hello", ~namespace=Uuid.Namespace.url)
// => "c6235813-3ba4-3801-ae84-e0a6ebb7d138"

// Using custom namespace
let myNamespace = Uuid.Namespace.custom("1b671a64-40d5-491e-99b0-da01ff1f3341")
let id = Uuid.v3(~name="mydata", ~namespace=myNamespace)
```

### `v5(~name, ~namespace)` - Namespace UUID (SHA-1)

Generates a UUID v5 (namespace-based with SHA-1 hash).

```rescript
// Using predefined DNS namespace
let id = Uuid.v5(~name="hello.example.com", ~namespace=Uuid.Namespace.dns)
// => "fdda765f-fc57-5604-a269-52a7df8164ec"

// Using predefined URL namespace
let id = Uuid.v5(~name="http://example.com/hello", ~namespace=Uuid.Namespace.url)
// => "3bbcee75-cecc-5b56-8031-b6641c1ed1f1"

// Using custom namespace
let myNamespace = Uuid.Namespace.custom("1b671a64-40d5-491e-99b0-da01ff1f3341")
let id = Uuid.v5(~name="mydata", ~namespace=myNamespace)
```

### `Namespace` Module

Predefined and custom namespaces for v3 and v5 UUID generation.

```rescript
Uuid.Namespace.dns  // DNS namespace (6ba7b810-9dad-11d1-80b4-00c04fd430c8)
Uuid.Namespace.url  // URL namespace (6ba7b811-9dad-11d1-80b4-00c04fd430c8)
Uuid.Namespace.custom(uuidString)  // Create custom namespace from UUID string
```

## Complete Example

```rescript
open Uuid

// Generate different UUID versions
let timestampId = v1()
Js.Console.log2("v1 (timestamp):", timestampId)

let randomId = v4()
Js.Console.log2("v4 (random):", randomId)

let dnsBasedId = v3(~name="example.com", ~namespace=Namespace.dns)
Js.Console.log2("v3 (DNS namespace):", dnsBasedId)

let urlBasedId = v5(~name="https://example.com", ~namespace=Namespace.url)
Js.Console.log2("v5 (URL namespace):", urlBasedId)

// Using custom namespace
let myNamespace = Namespace.custom("1b671a64-40d5-491e-99b0-da01ff1f3341")
let customId = v5(~name="my-resource-name", ~namespace=myNamespace)
Js.Console.log2("v5 (custom namespace):", customId)
```

## UUID Version Comparison

| Version | Algorithm | Use Case |
|---------|-----------|----------|
| v1 | Timestamp + MAC address | When you need time-ordered UUIDs |
| v3 | MD5 hash of namespace + name | When you need deterministic UUIDs (legacy) |
| v4 | Random | General purpose, most common |
| v5 | SHA-1 hash of namespace + name | When you need deterministic UUIDs (preferred over v3) |

## Notes

- **v4** is the most commonly used version for general purposes
- **v3** and **v5** generate the same UUID for the same name+namespace combination (deterministic)
- **v5** is preferred over **v3** when you need namespace-based UUIDs (SHA-1 vs MD5)
- **v1** includes timestamp and MAC address, which may have privacy implications

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
