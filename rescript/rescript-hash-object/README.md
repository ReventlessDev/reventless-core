[![npm version](https://img.shields.io/npm/v/@reventlessdev/rescript-hash-object.svg?label=version)](https://www.npmjs.com/package/@reventlessdev/rescript-hash-object)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Changelog](https://img.shields.io/badge/📋-Changelog-blue)](./CHANGELOG.md)

# `rescript-hash-obj`

ReasonML / Bucklescript bindings for [hash-obj](https://github.com/puleos/object-hash).

## Usage
- Add `rescript-hash-obj` to your dependencies in `package.json`.
- Add `rescript-hash-obj` to your dependencies in `rescript.json`.
- For general information see this monorepo's [readme](../../README.md)

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
