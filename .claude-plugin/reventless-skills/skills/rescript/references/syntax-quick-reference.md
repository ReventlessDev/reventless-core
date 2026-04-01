# ReScript v12 Syntax Quick Reference

## Let Bindings

```rescript
let x = 42
let name: string = "hello"
let mutable count = ref(0)
```

## Functions

```rescript
// Named function
let add = (a, b) => a + b

// With type annotations
let greet = (name: string): string => "Hello " ++ name

// Labeled arguments
let make = (~name: string, ~age: int=0, ()) => {name, age}

// Async functions
let fetch = async (url: string): string => {
  let response = await Http.get(url)
  response.body
}
```

## Pattern Matching

```rescript
// Switch on variants
switch status {
| Active => "active"
| Inactive(reason) => "inactive: " ++ reason
}

// Switch on option
switch maybeValue {
| Some(v) => process(v)
| None => fallback()
}

// Switch on result
switch result {
| Ok(value) => use(value)
| Error(err) => handleError(err)
}

// Tuple destructuring
let (a, b) = pair

// Record destructuring
let {name, age} = person
```

## Types

```rescript
// Record
type person = {name: string, age: int, email?: string}

// Variant
type shape =
  | Circle(float)
  | Rectangle(float, float)
  | Point

// Variant with inline records
type command =
  | Add({name: string, price: float})
  | Remove({id: string})

// Polymorphic variant (avoid unless needed for interop)
type color = [#red | #green | #blue]

// Type parameters
type result<'a, 'e> = Ok('a) | Error('e)
```

## Records

```rescript
// Create
let p = {name: "Alice", age: 30}

// With optional field — do NOT use Some()
let p2 = {name: "Bob", age: 25, email: "bob@example.com"}

// Update (spread)
let p3 = {...p, age: 31}

// Single-field record — do NOT spread (warning 23)
let s = {count: 5}  // not {...state, count: 5}
```

## Arrays and Lists

```rescript
// Array (preferred)
let arr = [1, 2, 3]
arr->Array.map(x => x * 2)
arr->Array.filter(x => x > 1)
arr->Array.forEach(x => Console.log(x))
arr->Array.reduce(0, (acc, x) => acc + x)

// Safe array access (returns option)
arr->Array.get(0)

// Unsafe array access (no option, requires intermediate variable for chaining)
let first = arr->Array.getUnsafe(0)
first.someField  // NOT arr->Array.getUnsafe(0).someField
```

## String Operations

```rescript
let s = "hello " ++ "world"
let len = String.length(s)
let upper = String.toUpperCase(s)
let contains = String.includes(s, "hello")
let parts = String.split(s, " ")
```

## Option and Result

```rescript
// Option
let x: option<int> = Some(42)
let y: option<int> = None

// There is NO Result.toOption — use inline switch
let optFromResult = switch result {
| Ok(v) => Some(v)
| Error(_) => None
}

// Option.map, Option.getOr
let doubled = x->Option.map(n => n * 2)
let withDefault = y->Option.getOr(0)
```

## Promise / Async

```rescript
// Async function
let fetchData = async () => {
  let result = await Api.get("/data")
  result.body
}

// Promise chaining (avoid — prefer async/await)
promise->Promise.then(value => { ... })
```

## Pipe Operator

```rescript
// Pipe first argument
value->func(arg2, arg3)

// Equivalent to
func(value, arg2, arg3)

// Chaining
items
->Array.filter(item => item.active)
->Array.map(item => item.name)
->Array.joinWith(", ")
```

## Exceptions

```rescript
// Modern exception handling (not Js.Exn)
try {
  riskyOperation()
} catch {
| JsExn.Error(e) => Console.error(JsExn.message(e))
}

// Deprecated — do NOT use:
// Js.Exn.asJsExn → use JsExn.fromException
// Js.Exn.message → use JsExn.message
```

## Module Basics

```rescript
// Define a module
module Utils = {
  let format = (s: string) => String.trim(s)
}

// Open a module (use sparingly)
open Array

// Local open
Array.map(items, item => ...)

// Module alias
module A = Very.Long.Module.Path
```

## Attributes

```rescript
// Schema generation (sury-ppx)
@schema type event = Added({name: string})

// Raw JavaScript
let now: unit => float = %raw(`() => Date.now()`)

// Module URL (required for dynamic import in Reventless)
let moduleUrl: string = %raw(`import.meta.url`)

// Suppress file-level warnings
@@warning("-44")
```

## Comparison with JavaScript

| JavaScript | ReScript v12 |
|-----------|-------------|
| `const x = 5` | `let x = 5` |
| `let x = 5` (mutable) | `let x = ref(5)` |
| `x = 10` | `x := 10` |
| `obj.key` | `obj.key` (same) |
| `{...obj, key: val}` | `{...obj, key: val}` (same) |
| `arr[0]` | `arr->Array.getUnsafe(0)` |
| `arr.map(f)` | `arr->Array.map(f)` |
| `async/await` | `async/await` (same) |
| `try/catch` | `try { } catch { \| pattern => }` |
| `console.log` | `Console.log` |
| `null/undefined` | `None` (option type) |
| `if/else` | `if/else` or `switch` |
| Template literals | `"hello " ++ name` |
