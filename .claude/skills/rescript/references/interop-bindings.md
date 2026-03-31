# ReScript JS Interop Patterns

## @module — Import from JS/npm Packages

```rescript
// Import a default export
@module("uuid") external v4: unit => string = "v4"

// Import a named export
@module("@modelcontextprotocol/sdk")
external newServer: (serverInfo, options) => server = "Server"

// Import with nested path
@module("sury/src/Sury.res.mjs")
external _jsNullable: (S.t<'a>, unit) => S.t<option<'a>> = "js_nullable"
```

## @val — Bind to Global Values

```rescript
// Global function
@val external setTimeout: (unit => unit, int) => timeoutId = "setTimeout"

// Global object property
@val external document: document = "document"

// Jest globals (required in ESM mode — not injected as bare globals)
@module("@jest/globals") external jest: jestObj = "jest"

// Native test binding (async-aware, unlike testPromise)
@val external jestTest: (string, unit => promise<unit>) => unit = "test"
```

## @send — Call Methods on Objects

```rescript
// Method call
@send external listen: (server, int, unit => unit) => unit = "listen"

// Usage: server->listen(3000, () => Console.log("started"))

// Method with return
@send external toString: (int, ~radix: int=?) => string = "toString"
```

## @get / @set — Property Access

```rescript
@get external getName: element => string = "name"
@set external setName: (element, string) => unit = "name"
```

## @scope — Access Nested Objects

```rescript
@scope("Math") @val external random: unit => float = "random"
@scope("JSON") @val external parse: string => 'a = "parse"
@scope("JSON") @val external stringify: 'a => string = "stringify"
```

## %raw — Inline JavaScript

```rescript
// Expression
let now: unit => float = %raw(`() => Date.now()`)

// Module URL (required for Reventless dynamic imports)
let moduleUrl: string = %raw(`import.meta.url`)

// Multi-line raw JS
let complexOp = %raw(`
  function(x, y) {
    return x * y + Math.random();
  }
`)
```

## @unboxed — Zero-Cost Wrappers

```rescript
@unboxed type stringOrNumber = String(string) | Number(float)
```

## Obj.magic — Unsafe Type Coercion

Use sparingly, only when the type system cannot express the relationship:

```rescript
// Coerce component type for operations access
let ops = component->Obj.magic->Component.operations

// Stub unused builder values
let make = (...): component => Obj.magic(0)  // satisfies module type only
```

**Rule:** Add a comment explaining why `Obj.magic` is necessary whenever you use it.

## External Type Declarations

Declare types for JS objects you interact with:

```rescript
type httpRequest = {
  method: string,
  url: string,
  headers: Dict.t<string>,
}

type httpResponse = {
  statusCode: int,
  mutable body: string,
}
```

## Common Binding Patterns

### Event Emitter
```rescript
type eventEmitter
@send external on: (eventEmitter, string, 'a => unit) => unit = "on"
@send external emit: (eventEmitter, string, 'a) => unit = "emit"
```

### Promise-Returning Functions
```rescript
@module("fs/promises")
external readFile: (string, string) => promise<string> = "readFile"
```

### Constructor Functions
```rescript
type server
@new @module("http") external createServer: (request => unit) => server = "Server"
```

### Variadic Arguments
```rescript
@variadic @val external log: array<string> => unit = "console.log"
```
