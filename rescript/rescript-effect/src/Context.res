/**
ReScript bindings for `Context` — an immutable map from typed `Tag`s to service implementations.

`Context` is the runtime carrier of the `'r` (requirements) channel. You rarely interact
with it directly; instead use `Effect.serviceWith`, `Effect.provideService`, and `Layer`.

**Typical pattern**
```rescript
// 1. Declare a tag identifying the service type
let myTag: Context.tag<MyService.t> = Context.genericTag("MyApp/MyService")

// 2. Use the service in an Effect — the 'r channel is now MyService.t
let useService = Effect.serviceWith(myTag, svc => svc.doThing())

// 3. Satisfy the requirement at the application boundary
useService
->Effect.provideService(myTag, liveImpl)
->Effect.runPromise
```
*/

/**
An opaque tag that identifies a service of type `'a`.

Two tags with the same string key but different `'a` annotations are distinct at runtime.
*/
type tag<'a>

/**
Creates a new tag identified by `key`.

The `'a` type is fixed by a type annotation at the call site:
```rescript
let loggerTag: Context.tag<Logger.t> = Context.genericTag("MyApp/Logger")
```

> **Note** Keys must be globally unique within the application. Use a namespaced
string (e.g. `"MyApp/Logger"`) to avoid collisions with third-party services.
*/
@module("effect/Context")
external genericTag: string => tag<'a> = "GenericTag"
