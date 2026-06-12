# @reventlessdev/rescript-jest

Direct ReScript bindings to Jest's global APIs, with **throwing `expect`** and
**native async test bodies**.

This is the single, shared replacement for the per-package Jest binding modules
the monorepo used to hand-roll (`AsyncTest`, `TestHelpers`, `JestBind`). ReScript
module visibility is per-package, so each package that needed async-capable,
throwing-`expect` bindings re-wrote them; this package consolidates that surface
at the bottom of the dependency graph.

## Why not `@glennsl/rescript-jest`?

glennsl's assertion model is deferred by design: `expect |> toBe` builds a value
that only executes when it is *returned* from the test body (one affirmed
assertion per test). A mid-test assertion whose result is not returned is
silently inert — a forgotten `return` passes green. Its `testPromise` also
discards the returned Promise, so async tests in a `describe` block race.

These bindings call Jest's globals directly: every `expect(...)->toBe(...)`
executes at its line, and `async () => ...` test bodies are awaited.

## Usage

```rescript
open JestGlobals

describe("widget", () => {
  testSync("adds", () => {
    expect(1 + 1)->toBe(2)
  })

  test("loads async", async () => {
    let v = await fetchValue()
    expect(v)->toEqual(expected)
  })
})
```

`test` registers an **async** test; `testSync` a synchronous one. `beforeAll` /
`afterAll` are synchronous; `beforeAllAsync` / `afterAllAsync` await a returned
promise. Matchers are available both flat and under `module Expect`.
