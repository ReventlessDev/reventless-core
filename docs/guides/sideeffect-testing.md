# Testing aggregate-style SideEffects

`SideEffect_GWT` is the test DSL for `Reventless.SideEffect.T` — the
aggregate-style egress mechanism that mirrors the DCB-side
`OutboundTranslationSlice`. The DSL reads inputs (`id` + `meta` + `event`),
runs the SE's `execute` against a stub `QueryEngine.operations`, then asserts
on the external calls the SE made.

The hard part is mocking: `SideEffect.T.execute` returns `promise<unit>` and
reaches external services through direct module imports. There is no DI seam
in the spec itself. The framework therefore picks **Option C** of the
`sideeffect-gwt` plan: do not change `SideEffect.T`; introduce a small
per-service convention for the modules that SideEffects call.

## The pattern

A *service module* (the thing a `SideEffect` calls — `EmailService`, `Sms`,
`Stripe`, …) holds its implementation in a `ref<backend>` so test code can
swap it.

```rescript
// src/Service/EmailService.res
type backend = {
  sendOrderConfirmation: (~email: string, ~orderId: string) => promise<unit>,
}

let liveBackend: backend = {
  sendOrderConfirmation: async (~email as _, ~orderId as _) => {
    // real HTTP call in production
    Console.log("[EmailService] Order confirmation sent")
  },
}

let current = ref(liveBackend)

let sendOrderConfirmation = (~email, ~orderId) =>
  current.contents.sendOrderConfirmation(~email, ~orderId)
```

A *mock module* — by convention `<Service>_Mock.res` next to the GWT file —
installs a recording backend and exposes a `mock` value the GWT consumes.

```rescript
// tests/Order/SideEffect/EmailService_Mock.res
@schema
type call = SendOrderConfirmation({email: string, orderId: string})

let calls: ref<array<call>> = ref([])

let reset = () => calls := []

let recordingBackend: EmailService.backend = {
  sendOrderConfirmation: async (~email, ~orderId) => {
    calls := calls.contents->Array.concat([SendOrderConfirmation({email, orderId})])
  },
}

let install = () => {
  EmailService.current := recordingBackend
  reset()
}

let mock: ReventlessGwt.SideEffect_GWT.mock<call> = {
  snapshot: () => calls.contents,
  encode: c => c->S.reverseConvertToJsonOrThrow(callSchema),
}
```

The GWT test follows the same shape as the other Reventless GWT DSLs.

```rescript
// tests/Order/SideEffect/Order_EmailNotification_GWT.res
@@reventless.gwt

describe("Order_EmailNotification SideEffect", () => {
  test("Placed triggers a confirmation email", () => {
    EmailService_Mock.install()
    givenEventForId(
      Order.Id.makeFromString("o1"),
      Order.Placed({customerId: "alice@example.com", productIds: ["p1"]}),
    )
    ->whenExecuted(EmailService_Mock.mock)
    ->thenExternalCalls([
      EmailService_Mock.SendOrderConfirmation({email: "alice@example.com", orderId: "o1"}),
    ])
  })

  test("Shipped is a no-op", () => {
    EmailService_Mock.install()
    givenEvent(Order.Shipped)
    ->whenExecuted(EmailService_Mock.mock)
    ->thenNoExternalCalls
  })
})
```

`@@reventless.gwt` derives the kind from the `SideEffect/` folder and the
spec from the filename stem (`Order_EmailNotification`) — the PPX emits
`open Order_EmailNotification; include SideEffect_GWT.Make(Order_EmailNotification)`
at the top of the file.

## Assertion surface

| Combinator | Use |
|---|---|
| `givenEvent(event)` | Default `id` and `meta`; just supplies the event. |
| `givenEventForId(id, event)` | Override the aggregate ID (drives `orderId` in the example). |
| `givenMeta(input, meta)` | Override the envelope metadata. |
| `whenExecuted(input, mock, ~queryEngine=?)` | Run `SE.execute`. Pass a stub `QueryEngine.operations` if the SE reads read models. |
| `thenExternalCalls(promise, expected)` | Captured calls must equal `expected`. Fails with an `EventsMismatch` rendered through the mock's `encode`. |
| `thenNoExternalCalls(promise)` | Captured array must be empty. |
| `thenExternalCallCount(promise, n)` | Captured array length must equal `n` (useful when payloads vary). |

## Contrast with `OutboundTranslation_GWT`

| | `SideEffect_GWT` | `OutboundTranslation_GWT` |
|---|---|---|
| Architecture | Aggregate-style egress | DCB-style egress |
| Unit under test | `SE.execute` (`promise<unit>`) | `Slice.translate` (mocked) |
| Mocking | Per-service `_Mock.res` + ref-backed `backend` | `whenTranslateMocked` supplies a lambda |
| Output of `execute` | Recorded via mock; the framework doesn't see it directly | The lambda's return value (commands + retry status) |
| Retry support | Out of scope (SideEffect retries are runtime concerns) | `whenTranslateRetrying(~maxRetries)` |

If your example needs to test both styles, see
`examples/online-shop-aggregates/ordering/tests/Order/SideEffect/` and
`examples/online-shop-hybrid/ordering/tests/.../OutboundTranslationSlice/`.

## Why not refactor `SideEffect.T` for DI?

The plan considered adding a `Service` module parameter to the spec (Option
A). That would be the cleanest DI seam, but it touches every existing
`SideEffect` and the `Task` plumbing in `reventless-spec`. The ref-backed
backend pattern is local to each service module, costs zero framework
changes, and is invisible at SE call sites. Revisit Option A only if an
example accumulates more than a handful of services that all want this
pattern.
