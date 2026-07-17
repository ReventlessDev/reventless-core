# ReScript `option` + JavaScript Proxy = `BS_PRIVATE_NESTED_SOME_NONE`

## The Problem

When a `Pulumi.Output.t` (or any JavaScript Proxy object) is wrapped in ReScript's `option` type via `Some(proxyValue)`, the resulting value is **not** `Some(proxyValue)` — it is the sentinel object `{BS_PRIVATE_NESTED_SOME_NONE: 0}`. This silently corrupts the value.

## How It Happens

### Step 1: ReScript's `Some()` implementation

ReScript compiles `Some(value)` to `Caml_option.some(value)` (or `Primitive_option.some` in v12). This function has special logic to detect **nested options** (`Some(Some(x))`) at runtime:

```javascript
// From @rescript/runtime — Primitive_option.js (simplified)
function some(x) {
  if (x !== undefined && x !== null && x.BS_PRIVATE_NESTED_SOME_NONE !== undefined) {
    // x looks like it's already a Some — wrap it to distinguish Some(Some(x)) from Some(x)
    return { BS_PRIVATE_NESTED_SOME_NONE: 0, val: x };
  }
  return x;  // x IS the Some representation (identity-wrapped)
}
```

The key line: `x.BS_PRIVATE_NESTED_SOME_NONE !== undefined` — it checks whether the value already has this sentinel property.

### Step 2: Pulumi Output is a JavaScript Proxy

`Pulumi.Output.t` is implemented as a [JavaScript Proxy](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Proxy) (see [Pulumi SDK source](https://github.com/pulumi/pulumi/blob/afac93f70cde7c89eb8c5820b490c917f540ef2e/sdk/nodejs/output.ts#L264)). A Proxy intercepts **all** property accesses, including non-existent properties:

```javascript
const output = pulumi.output("hello");

// Normal object: accessing a non-existent property returns undefined
const plain = { foo: 1 };
plain.BS_PRIVATE_NESTED_SOME_NONE  // → undefined  ✓

// Proxy: accessing ANY property returns a truthy value (another Output/Proxy)
output.BS_PRIVATE_NESTED_SOME_NONE  // → Output<...>  (truthy!)  ✗
```

### Step 3: The Collision

When ReScript executes `Some(pulumiOutput)`:

1. `Caml_option.some(pulumiOutput)` is called
2. It checks `pulumiOutput.BS_PRIVATE_NESTED_SOME_NONE !== undefined`
3. The Proxy intercepts the property access and returns a truthy value (another Output)
4. The check passes — ReScript thinks the value is a nested `Some(Some(...))`
5. It returns `{BS_PRIVATE_NESTED_SOME_NONE: 0, val: pulumiOutput}` (the sentinel wrapper)

When this wrapped value is later stored in a Pulumi stack export, Pulumi serializes it as `{"BS_PRIVATE_NESTED_SOME_NONE": 0}` — the actual value is lost.

## Where This Bites

Any ReScript code that wraps a `Pulumi.Output.t` in `option`:

```rescript
// ✗ BROKEN — Some() wraps the Proxy, producing the sentinel
let ref: ref<option<Pulumi.Output.t<'a>>> = ref(None)
ref := Some(myOutput)  // ← corrupted!

// ✗ BROKEN — optional record fields use Some() internally
type config = {value?: Pulumi.Output.t<string>}
let c = {value: myOutput}  // ← corrupted!

// ✗ BROKEN — function returning option<Output.t>
let f = (): option<Pulumi.Output.t<string>> => Some(myOutput)  // ← corrupted!
```

Also affects `Nullable.toOption` — converting from `Nullable.t` to `option` still calls `some()`.

### Concrete Example: `_interopMeta` Stack Export

The `interopMetaOutput` ref stored `option<Pulumi.Output.t<JSON.t>>`. The `Some(output)` call corrupted the Output into the BS_PRIVATE sentinel. When Pulumi serialized the stack export, it wrote `{"BS_PRIVATE_NESTED_SOME_NONE": 0}` instead of the actual metadata.

## Workarounds

### 1. Use raw `null` instead of `option` (recommended for refs)

```rescript
// Initialize with raw null — no option wrapping
let myRef: ref<Pulumi.Output.t<JSON.t>> = ref(%raw(`null`))

// Assign directly — no Some() wrapper
myRef := myOutputValue

// Read with raw null check — no Option.getOrThrow (which uses Caml_option internally)
let getValue = (): Pulumi.Output.t<JSON.t> => {
  let v = myRef.contents
  if %raw(`v === null`) {
    Exn.raiseError("not initialized")
  } else {
    v
  }
}
```

### 2. Make required fields non-optional

```rescript
// ✗ optional Output field — triggers the bug
type args = {id?: Pulumi.Input.t<string>}

// ✓ required field — no Some() wrapping
type args = {id: Pulumi.Input.t<string>}
```

This is not always possible (AWS resource configs have many optional fields).

### 3. Use `@obj external` for record constructors (deprecated)

```rescript
// ✓ Bypasses ReScript's record field handling
module Args = {
  type t
  @obj external make: (~id: Pulumi.Input.t<string>=?) => t = ""
}
let args = Args.make(~id=myOutput->Output.asInput)
```

The `@obj` attribute generates a plain JS object constructor that doesn't use `Caml_option.some()`. However, `@obj` is deprecated in ReScript v12 and will be removed.

### 4. Avoid `option` in the type entirely

Store the Output directly and use a boolean flag or sentinel value for the "not set" state:

```rescript
let isSet: ref<bool> = ref(false)
let myOutput: ref<Pulumi.Output.t<'a>> = ref(Pulumi.Output.make(%raw(`undefined`)))

// Set
isSet := true
myOutput := actualOutput

// Get
if isSet.contents { Some(myOutput.contents) } else { None }
```

## General Rule

> **Never wrap a JavaScript Proxy in ReScript's `option` type.**
>
> This includes `Pulumi.Output.t`, `Pulumi.Input.t`, and any other Proxy-based value.
> Use raw null/undefined checks, required fields, or `@obj external` constructors instead.

## References

- ReScript runtime: [`Primitive_option.some`](https://github.com/rescript-lang/rescript/blob/main/runtime/Primitive_option.res) — the `BS_PRIVATE_NESTED_SOME_NONE` check
- Pulumi SDK: [Output as Proxy](https://github.com/pulumi/pulumi/blob/afac93f70cde7c89eb8c5820b490c917f540ef2e/sdk/nodejs/output.ts#L264)
- Pulumi issue: [pulumi-terraform-bridge#62](https://github.com/pulumi/pulumi-terraform-bridge/issues/62) — Pulumi panic on the sentinel
- This repo: [`rescript-pulumi-pulumi/src/Rescript11Problem.res`](https://github.com/ReventlessDev/reventless-core/blob/main/rescript/rescript-pulumi-pulumi/src/Rescript11Problem.res) — original problem documentation with reproduction code
- This repo: [`rescript-pulumi-pulumi/src/Output.res`](https://github.com/ReventlessDev/reventless-core/blob/main/rescript/rescript-pulumi-pulumi/src/Output.res) lines 83-87 — earlier workaround attempt
- Fix applied: [`Plugin_Helpers.res`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/core/src/components/Plugin/Plugin_Helpers.res) — `interopMetaOutput` ref uses raw null instead of `option`
