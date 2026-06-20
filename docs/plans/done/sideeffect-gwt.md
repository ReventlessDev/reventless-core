# Plan: Add `SideEffect_GWT` — Test DSL for Aggregate-Style Egress

## Why

`reventless-gwt` ships per-component test DSLs that mirror each runtime
component:

| Component | Test DSL | Style |
|---|---|---|
| Aggregate behavior | `Behavior_GWT.MakeFromAggregate` | aggregate |
| StateChangeSlice behavior | `Behavior_GWT.Make` / `CommandStep` | DCB |
| Read model projection | `Projection_GWT`, `MultiSourceProjection_GWT` | both |
| StateViewSlice projection | `Projection_GWT` | DCB |
| Automation | `Automation_GWT`, `Flow_GWT.AutomationStep` | DCB |
| Inbound translation | `InboundTranslation_GWT` | DCB |
| **Outbound translation** | **`OutboundTranslation_GWT`** | **DCB** |
| ExtensionPoint mapping | `Mapping_GWT` | both |
| Extension mapping | `Mapping_GWT` | both |
| **SideEffect (aggregate egress)** | **— missing —** | **aggregate** |

`OutboundTranslation_GWT` covers the DCB egress mechanism. `SideEffect` is its
aggregate-style counterpart — labelled "SideEffect (aggregate approach only)"
in `docs/analysis/reventless-markdown-spec-conversion.md` §2.15, and described
alongside `OutboundTranslationSlice.translate` in
`docs/analysis/done/event-graph-linking.md` as the two parallel external-call
mechanisms. The aggregate-style egress has no test DSL today.

Concretely: `examples/online-shop-aggregates/ordering/src/Order/SideEffect/Order_EmailNotification.res`
exists but has no GWT next to it. The hybrid example ships
`SendOrderConfirmation_GWT` for its DCB OutboundTranslationSlice; the
aggregates example can't symmetrically demonstrate testable egress.

## Goal

`SideEffect_GWT.Make(SE: SideEffect.T)` produces a test DSL with the same
shape as `OutboundTranslation_GWT.Make` adapted to SideEffect's runtime
contract:

- inputs: `Source.event` + `Message.meta` + a stub `QueryEngine.operations`
- assertion surface: what the SideEffect did (which external service got
  called, with which arguments)

So an aggregate-side egress test reads alongside the slice's:

```rescript
@@reventless.gwt

describe("Order_EmailNotification SideEffect", () => {
  testSync("Placed triggers sendOrderConfirmation", () =>
    givenEvent(Order.Placed({customerId: "c1", productIds: ["p1"]}))
    ->whenExecutedMocked(EmailService.Mock.make())
    ->thenExternalCalls([
      EmailService.Mock.SendOrderConfirmation({email: "c1", orderId: "o1"}),
    ])
  )

  testSync("Shipped is ignored", () =>
    givenEvent(Order.Shipped)
    ->whenExecutedMocked(EmailService.Mock.make())
    ->thenNoExternalCalls
  )
})
```

## The constraint: SideEffect.execute has no DI seam

```rescript
// reventless-spec/src/types/SideEffect.res
module type T = {
  module Source: Source
  let moduleUrl: string
  let execute: (Source.Id.t, Message.meta, Source.event, QueryEngine.operations) => promise<unit>
}
```

`execute` returns `promise<unit>` — opaque. Whatever external service it calls
(`EmailService.sendOrderConfirmation`, `Sms.send`, …) is referenced **directly
by module import** inside the body. There is no parameter to swap for a mock.

`OutboundTranslation_GWT` sidesteps this by mocking `translate` itself
(`whenTranslateMocked` supplies an alternative `translate` lambda). That trick
doesn't work for `SideEffect` because the unit under test IS `execute`, and
swapping `execute` is testing the test mock, not the real code.

The plan therefore has to pick a mocking strategy. Three options below; the
recommendation is **Option C**.

### Option A — refactor `SideEffect.T` to take a Service module

Add a generic `Service` parameter to the spec:

```rescript
module type T = {
  module Source: Source
  module Service: {type api}  // or a free type parameter
  let moduleUrl: string
  let execute: (Source.Id.t, Message.meta, Source.event, QueryEngine.operations, Service.api) => promise<unit>
}
```

The runtime adapter passes the real `Service.api`; the GWT passes a stub.

**Pros:** clean DI; test surface symmetric with `OutboundTranslation_GWT`.
**Cons:** breaking change to `SideEffect.T`; touches every existing SideEffect
in core + examples; requires plumbing the Service through `Task.Spec` and
`Task_Builder`.

### Option B — Jest module-mock at the service boundary

Use `jest.mock('./EmailService')` in the test file; `SideEffect_GWT` records
calls via the mock's `mock.calls` array.

**Pros:** zero framework change.
**Cons:** test boilerplate per service module; depends on `jest.mock` hoisting,
which is fragile under ESM + `--experimental-vm-modules`; assertion error
messages stringify mock-call records, not domain values; can't be expressed
in the `givenEvent->whenExecuted->thenX` chain idiomatically.

### Option C — small `Service.T` convention without changing `SideEffect.T` (Recommended)

Don't touch `SideEffect.T`. Instead, introduce a tiny convention for the
**services that SideEffects call**:

```rescript
// app code — Service/EmailService.res
module type T = {
  let sendOrderConfirmation: (~email: string, ~orderId: string) => promise<unit>
  // …
}

module Live: T = {
  let sendOrderConfirmation = async (~email as _, ~orderId as _) => {
    // real HTTP call
    Console.log("[EmailService] Order confirmation sent")
  }
}

// the rest of the codebase pulls `Live` re-exported as the bare module:
include Live
```

`SideEffect_GWT.Make` exposes a `MockService` helper used by tests instead of
`include Live`. Pattern:

```rescript
// reventless-gwt/src/SideEffect_GWT.res — sketch

module type ServiceCapture = {
  type call
  let make: unit => (module ServiceSnapshot)
}
module type ServiceSnapshot = {
  type call
  let calls: array<call>
}
```

The SE under test imports the service module as usual (compile-time binding).
At test time the test file imports a hand-written `*Mock.res` next to the
service that records calls into a ref. `SideEffect_GWT` runs `SE.execute` then
reads the mock's recorded calls — no framework change, but a per-service
`Mock.res` helper.

**Pros:** zero framework change to `SideEffect.T`; no jest.mock plumbing; test
chain reads idiomatically.
**Cons:** one `Mock.res` per service module the user wants to assert against;
`SideEffect_GWT` only knows about the captured-call list, not the service
identity (so cross-service assertions need a discriminating tag).

**Recommendation:** Option C. The framework-change surface is zero, the
test-surface mirrors `OutboundTranslation_GWT`, and the per-service mock
modules are small and obvious. If a future plan wants to consolidate
Service-mock plumbing, that can be a follow-up.

## Scope

### Framework (`reventless-gwt/src/SideEffect_GWT.res`)

New module. Mirrors `OutboundTranslation_GWT` where shapes align:

```rescript
module type Spec = {
  let name: string
  module Source: SideEffect.Source
}

module type T = {
  module Spec: Spec

  let describe: (string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => promise<Outcome.outcome>) => unit
  let testSync: (string, unit => Outcome.outcome) => unit

  // Pipeline state.
  type input = {
    id: Spec.Source.Id.t,
    meta: Message.meta,
    event: Spec.Source.event,
  }

  // given*
  let givenEvent: Spec.Source.event => input
  let givenEventForId: (Spec.Source.Id.t, Spec.Source.event) => input
  let givenMeta: (input, Message.meta) => input

  // when* — runs execute against a stub QueryEngine + a Service snapshot
  // collector. Returns the snapshot for assertion.
  let whenExecuted: (input, ~queryEngine: QueryEngine.operations=?) => promise<snapshot>

  // then*
  let thenNoExternalCalls: promise<snapshot> => promise<Outcome.outcome>
  let thenExternalCallCount: (promise<snapshot>, int) => promise<Outcome.outcome>
  // Generic key/value assertion on captured calls; concrete service mocks add
  // their own typed assertions that compose with this.
  let thenCapturedJson: (promise<snapshot>, array<JSON.t>) => promise<Outcome.outcome>
}

module Make: (
  SE: SideEffect.T,
  Spec: Spec with module Source = SE.Source,
) => T with module Spec = Spec
```

The `snapshot` type holds the captured calls and is opaque to the framework;
services register into it via a small `Capture` module.

### PPX support (`reventless-ppx`)

Extend the file-scope `@@reventless.gwt` PPX so `SideEffect/<Name>_GWT.res`
auto-injects `include ReventlessGwt.SideEffect_GWT.Make(<Spec>, <SpecMeta>)`.
Folder-name "SideEffect" already maps cleanly through the existing path
vocabulary used for `OutboundTranslationSlice`.

### Service-mock convention

Document the per-service `Mock.res` pattern in
`docs/guides/sideeffect-testing.md` (new). Example:

```rescript
// examples/online-shop-aggregates/ordering/src/Service/EmailService_Mock.res
@schema
type call =
  | SendOrderConfirmation({email: string, orderId: string})

let calls: ref<array<call>> = ref([])

let reset = () => calls := []

let sendOrderConfirmation = async (~email, ~orderId) =>
  calls := calls.contents->Array.concat([SendOrderConfirmation({email, orderId})])
```

Test files toggle between the real and mock service using a small interop
trick (e.g. module aliasing in the test's local scope, or by importing the
SideEffect under test from a `*_TestHarness.res` re-export that swaps the
service module via functor).

### Example: `Order_EmailNotification_GWT.res`

Live next to `Order_EmailNotification.res` in
`examples/online-shop-aggregates/ordering/tests/Order/SideEffect/`:

```rescript
@@reventless.gwt

describe("Order_EmailNotification SideEffect", () => {
  beforeEach(EmailService_Mock.reset)

  testSync("Placed triggers a confirmation email", () =>
    givenEventForId(
      Order.Id.makeFromString("o1"),
      Order.Placed({customerId: "alice@example.com", productIds: ["p1"]}),
    )
    ->whenExecuted
    ->thenCaptured([
      EmailService_Mock.SendOrderConfirmation({email: "alice@example.com", orderId: "o1"}),
    ])
  )

  testSync("Shipped is a no-op", () =>
    givenEvent(Order.Shipped)->whenExecuted->thenNoExternalCalls
  )
})
```

## Sequencing

1. **Framework**: write `SideEffect_GWT.res` with the API sketched above. No
   PPX changes yet — tests use the long form `include ReventlessGwt.SideEffect_GWT.Make(...)`.
2. **PPX**: extend `@@reventless.gwt` folder vocabulary to recognise
   `SideEffect/` and auto-inject the include.
3. **Examples**: add `EmailService_Mock.res` + `Order_EmailNotification_GWT.res`
   in `online-shop-aggregates` and document the mock convention in the README's
   "Pattern coverage" footer.
4. **Docs**: add `docs/guides/sideeffect-testing.md` covering the mock
   convention and contrasting with `OutboundTranslation_GWT`.

## Verification

- `pnpm test` from `reventless-gwt` passes with new fixtures exercising
  `SideEffect_GWT`.
- `pnpm test` from `examples/online-shop-aggregates/ordering` passes the new
  `Order_EmailNotification_GWT` test.
- Zero warnings under the repo's `-44+101` warnings policy.
- `examples/online-shop-aggregates/README.md` "Pattern coverage" table now
  lists SideEffect alongside a Test column.

## Out of scope

- `Flow_GWT.AggregateCommandStep` — the cross-plugin Flow test surface is
  DCB-only today. Adding aggregate-side steps is a separate plan and would
  unblock `examples/online-shop-aggregates/platform-local/tests/Flow/`.
- Refactoring `SideEffect.T` to take a Service module (Option A above) —
  bigger API change; revisit if Option C accumulates pain.
- Jest's ESM module-mock route (Option B) — not pursued.

## Risks

- **Service-mock proliferation.** Every service the example wants to test
  needs a `*_Mock.res`. For demos with one or two services this is fine; if a
  real app uses dozens, the mock surface gets noisy. Re-evaluate against
  Option A once we have ≥ 5 distinct services in any one example.
- **Test-time module swap mechanics.** Whether the SE under test imports
  `EmailService` or `EmailService_Mock` is decided at compile time. The plan
  needs to pick a concrete mechanism (functor parameter, top-level
  re-export, build flag) before implementation. Tentative pick: ship the
  SE in a `_TestHarness.res` that re-binds the service modules via a small
  functor — invisible to production code, present only in test sources.

## Open questions

- Should `SideEffect_GWT` ship `whenExecutedWith(~queryEngine)` to let tests
  pre-populate read-model state? Yes — but the stub `QueryEngine.operations`
  shape is non-trivial; defer to "rough first cut + iterate" rather than
  pre-spec it here.
- Should the captured-call list be a `array<JSON.t>` (uniform across services)
  or a service-specific variant? The plan above sketches both; pick the
  service-specific variant for ergonomic test bodies and add a
  `thenCapturedJson` escape hatch for cross-service assertions.
