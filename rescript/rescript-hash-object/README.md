[![npm](https://img.shields.io/npm/v/@reventlessdev/rescript-hash-object.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/rescript-hash-object)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/rescript-hash-object

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

ReScript bindings for [hash-obj](https://github.com/puleos/object-hash).

## Install

```bash
pnpm add @reventlessdev/rescript-hash-object
```

Add it to your `rescript.json` dependencies:

```json
{
  "dependencies": ["@reventlessdev/rescript-hash-object"]
}
```

## API Documentation

### `hashDict`

Generates a hash string from a dictionary object.

```rescript
hashDict: (~dict: dict<string>, ~options: Options.t=?) => string
```

**Parameters:**
- `dict`: A dictionary with string values to hash
- `options` (optional): Configuration options for hash generation

### Options

```rescript
type Options.t = {
  encoding?: encoding,
  algorithm?: algorithm,
}
```

**`encoding`** - Output encoding format:
- `Hex` (default) - Hexadecimal string
- `Base64` - Base64-encoded string
- `Buffer` - Raw buffer output
- `Latin1` - Latin1 string encoding

**`algorithm`** - Hash algorithm to use:
- `SHA256` (default) - SHA-256 algorithm
- `MD5` - MD5 algorithm
- `SHA1` - SHA-1 algorithm
- `SHA512` - SHA-512 algorithm

## Examples

### Basic usage (default SHA256 with hex encoding)

```rescript
open HashObj

let data = Dict.fromArray([("name", "Alice"), ("age", "30")])
let hash = hashDict(~dict=data)
// => "8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918"
```

### Using different algorithms

```rescript
open HashObj

let data = Dict.fromArray([("user", "bob"), ("id", "42")])

// MD5
let md5Hash = hashDict(~dict=data, ~options={algorithm: MD5})

// SHA1
let sha1Hash = hashDict(~dict=data, ~options={algorithm: SHA1})

// SHA512
let sha512Hash = hashDict(~dict=data, ~options={algorithm: SHA512})
```

### Using different encodings

```rescript
open HashObj

let data = Dict.fromArray([("key", "value")])

// Hex encoding (default)
let hexHash = hashDict(~dict=data, ~options={encoding: Hex})

// Base64 encoding
let base64Hash = hashDict(~dict=data, ~options={encoding: Base64})

// Latin1 encoding
let latin1Hash = hashDict(~dict=data, ~options={encoding: Latin1})
```

### Combining algorithm and encoding

```rescript
open HashObj

let data = Dict.fromArray([
  ("environment", "production"),
  ("version", "1.2.3"),
  ("region", "us-east-1"),
])

// SHA512 with Base64 encoding
let hash = hashDict(
  ~dict=data,
  ~options={
    algorithm: SHA512,
    encoding: Base64,
  },
)
```

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
