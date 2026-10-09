# Testing inbound and outbound translation slices

> **Status:** Analysis · no implementation. Filed 2026-10-09.
>
> **Questions and short answers:**
>
> 1. *How are translation slices tested today?* **On two levels that rarely meet.** The GWT
>    DSLs test the pure part: an inbound slice's `translate`, and an outbound slice's `collect`
>    plus a `translate` the test supplies itself. Fixture tests in `reventless/local/tests` test
>    the runtime: callbacks, audit rows, retries, `Abandoned` and `onExhausted`. No example
>    slice is run through the runtime, and no fixture slice through the DSL
>    ([§1](#1-what-exists)).
> 2. *What does that leave untested?* **For an outbound slice, its own `translate` is not part
>    of the DSL.** An example tests it only when the author passes it in as the "mock". The
>    DSL's status vocabulary and retry budget differ from the runtime's. `onExhausted`,
>    authorization, decoding the external payload, encoding the commands, and repeated
>    deliveries are not tested anywhere an author would look. Two findings go beyond testing:
>    **an inbound slice's `commandAuthorization` is enforced only on AWS, and there only for its
>    first command constructor**; and **inbound commands are encoded with `JSON.stringifyAny`,
>    not the command schema**
>    ([§2](#2-what-is-not-tested), [§3](#3-two-findings-that-are-not-about-tests)).
> 3. *How should they be tested?* **On four layers, each proving one thing**
>    ([§4](#4-how-they-should-be-tested)):
>    - a scenario per slice, with the real `translate` and recording capability fakes;
>    - the slice's runtime with statuses, retries and audit rows;
>    - a flow from the external message to the last view;
>    - the deployed door, the mutation now and the webhook later, with its authorization.
>
>    The scenario layer needs a DSL that takes the slice as written. The plan
>    [the-sidecars-read-automations-and-translations.md](../plans/done/the-sidecars-read-automations-and-translations.md)
>    builds that, and makes the scenarios readable by tools.

**Related:**
[given-when-then-specifications.md](./given-when-then-specifications.md) (the original DSL
sketch) ·
[gwt-test-type-coverage-and-opportunities.md](./gwt-test-type-coverage-and-opportunities.md) ·
[plans/done/translation-slice.md](../plans/done/translation-slice.md) ·
[plans/done/sideeffect-gwt.md](../plans/done/sideeffect-gwt.md) (the precedent for recording
external calls) ·
[plans/retry-exhaustion-is-not-a-state.md](../plans/retry-exhaustion-is-not-a-state.md) ·
[plans/trait-contact-verification.md](../plans/trait-contact-verification.md) (why capabilities
are injected) ·
[plans/Backlog/webhook-infrastructure.md](../plans/Backlog/webhook-infrastructure.md)

---

## 1. What exists

### 1.1 The two DSLs

**`InboundTranslation_GWT`** ([source](../../reventless/gwt/src/InboundTranslation_GWT.res))
takes a module with `externalInput`, `command` and `translate`. It has no *given*: a
translation has no prior state.

| Verb | What it does |
|---|---|
| `whenInput(input)` | calls `translate` on a **typed** value; no JSON is decoded |
| `thenCommands` / `thenCommand(id, cmd)` | structural `==` on the typed pairs |
| `thenNoCommand` | passes on `Ok([])` |
| `thenTranslateError(msg)` | exact match on `Error(msg)` |

**`OutboundTranslation_GWT`** ([source](../../reventless/gwt/src/OutboundTranslation_GWT.res))
takes `consumedEvent`, `outboundItem`, `inboundCommand` and `collect`. Its header says so
plainly: *"`translate` is async and supplied at test-time via `whenTranslateMocked` so the
external service is never hit. The spec's own `translate` is not part of the GWT."*

| Verb | What it does |
|---|---|
| `givenEvent` → `whenCollect(~sourceId)` → `thenTodos` | runs the real `collect` |
| `givenTodo` → `whenTranslateMocked(mock)` | awaits the supplied function once |
| `whenTranslateRetrying(~maxRetries, mock)` | calls it again while it returns `Error` |
| `thenCommand` / `thenNoCommand` | checks the answer's command |
| `thenTodoStatus(id, #Completed \| #Pending)` | derives a status from the result |
| `thenRetryRecorded(n)` | counts the re-attempts |

Neither DSL takes the slice as it is written. Spec and body live in two files, so every test
starts with an adapter module that the PPX picks up as "the first top-level module":

```rescript
// examples/online-shop-hybrid/ordering/tests/Customer/OutboundTranslation/GeocodeCustomerAddress_GWT.res
module GeocodeCustomerAddressSlice = {
  include GeocodeCustomerAddress
  let collect = GeocodeCustomerAddress_Translation.collect
}
@@reventless.gwt
let withGeocoder = answer => {
  let capabilities: Reventless.Capabilities.t = {
    ...Reventless.Capabilities.none,
    geocode: (~text as _) => Promise.resolve(answer),
  }
  (id, item) => GeocodeCustomerAddress_Translation.translate(id, item, ~capabilities)
}
```

The "mock" slot is filled with the real `translate`, partially applied to fake capabilities.
That is the right test, reached around the DSL rather than through it.

### 1.2 The example slices

| Slice | Tests | Real `translate` run? | External system faked by |
|---|---|---|---|
| ImportProduct, both shops (inbound) | 4 and 7 | yes (it is pure) | — |
| SendOrderConfirmation, DCB shop | 3 | **never**: the mocks are `_ => Ok(None)` and `_ => Error("smtp down")` | nothing; the real code calls `EmailService` directly, which has no seam |
| GeocodeCustomerAddress | 3 | 2 of 3 | `{...Capabilities.none, geocode}` |
| VerifyCustomerEmail | 8 | yes | `Secrets.fixed`, `Messaging.makeProvider(~send)`, refs that record the bodies sent, and a home-made `alsoThat` |
| SendNotification | 7 | yes | `Messaging.makeProvider` with a fixed answer |
| AnnounceRecipientContact | **0** | — | — |

### 1.3 Runtime tests, outside the DSLs

| Suite | Covers |
|---|---|
| `local/tests/.../InboundTranslationSliceCallbackTest.res` (8) | publish, audit `Success`/`Failure`, invalid JSON, publish failure, several commands, none |
| `local/tests/adapter/InboundTranslationMutationTest.res` (3) | the real GraphQL execution: `CommandAccepted`, `CommandRejected{TranslationFailed}`, `CommandResult!` |
| `aws/tests/DcbInboundTranslationRoutingTest.res` | the Lambda's inbound route, rejection path |
| `local/tests/.../OutboundTranslationSliceCallbackTest.res` (20) | phase 1 dedup, `Completed`/`Failed`/`Abandoned`, retry ceiling, `lastError`, `onExhausted` in four shapes, isolation between items |
| `local/tests/.../OutboundTranslationSlicePlatformTest.res` (2) | the real chain decision → log → collector → phase 1 → phase 2 |
| `traits/address-geocoding` conformance | the trait's real `translate` against scripted geocoder answers |

All of these use fixture slices, and every outbound fixture passes `Capabilities.none`. The
only run of a real example slice through the runtime is the hybrid shop's seed script, which
sends the real `Catalog_ImportProduct` mutation and counts audit rows. That is a script, not a
test.

### 1.4 Flows

`Flow_GWT.OutboundStep` runs `collect` over the shared log and compares the items. It does not
call `translate`, although
[gwt-flow-and-extension-test-kinds](../plans/done/gwt-flow-and-extension-test-kinds.md) says it
does. It passes `~sourceId=""`, so a slice keyed by its aggregate source cannot be checked.
**There is no inbound step:** a flow cannot start with a message from outside except by
calling `translate` by hand.

---

## 2. What is not tested

| # | Gap | Where it bites |
|---|---|---|
| 1 | **An outbound slice's own `translate` is not part of the DSL** | SendOrderConfirmation's real code is never run by a test; the guide's claim that "the spec's real `translate` is exercised in component callback tests" is not true for any example slice |
| 2 | **No assertion on what was sent.** Only `SideEffect_GWT` records external calls (`thenExternalCalls`) | VerifyCustomerEmail rebuilds it by hand with refs; message texts and request bodies built inside `translate` are untested elsewhere |
| 3 | **The DSL's statuses are not the runtime's.** It knows `#Completed \| #Pending`; the runtime writes `Pending \| Processing \| Completed \| Failed \| Abandoned`. An `Error` is `Failed` or `Abandoned` there, never `Pending`. An `Ok(Some)` whose publish fails is `Failed`, which the DSL reports as `#Completed` | a passing scenario can describe a state the runtime never reaches |
| 4 | **The retry budget differs.** In the DSL `maxRetries` counts re-attempts (up to `maxRetries + 1` calls); in the runtime it counts attempts (the row is `Abandoned` when `retryCount >= maxRetries`). The DSL's own self-test asserts 4 calls for `maxRetries = 3` | a scenario pins a retry count the deployed slice will not make |
| 5 | **`onExhausted` has no verb** | GeocodeCustomerAddress and SendNotification return commands from it; neither is tested |
| 6 | **An exception in `translate`** becomes `Error` at runtime; `whenTranslateMocked` lets it escape | a throwing client fails the test instead of being asserted |
| 7 | **The external payload is never decoded in a scenario.** `whenInput` takes a typed value | a wrong field name, a missing field or a format the `@schema` refuses is invisible; only one fixture test sends invalid JSON |
| 8 | **The commands are never encoded in a scenario.** `thenCommand` compares typed values | an encoding the target cannot decode passes the scenario (see [§3.2](#32-inbound-commands-are-encoded-without-their-schema)) |
| 9 | **Several commands, or none, from an example.** The DSL has `thenCommands` and `thenNoCommand`; no example uses them | — |
| 10 | **Repeated deliveries.** Inbound: every call gets a fresh `requestId`, no external message key exists, a repeated delivery publishes again. Outbound: when `translate` succeeds and the publish fails, the row is `Failed` and the next pass **calls the external system again**; `Messaging.send` takes no idempotency key | duplicate commands in, duplicate emails out |
| 11 | **A row left `Processing`** by a crash is excluded from the pending filter | it never runs again; no test covers recovery |
| 12 | **The audit row's content.** `targetIds`, `error` and `input` are written; only status and count are asserted | an operator reads fields no test pins |
| 13 | **`testSync` is not harvested** into the scenario sidecar, and most translation verbs are unknown to it | the tools see these slices as untested (the plan, gap 1) |

---

## 3. Two findings that are not about tests

### 3.1 Inbound `commandAuthorization` is enforced only on AWS, and only for the first constructor

The inbound spec declares `commandAuthorization: command => rule`, documented as "evaluated at
the GraphQL resolver entry before any external input is translated". Three places read it, and
they disagree:

| Where | What it does |
|---|---|
| **AWS door**: `Dcb_Builder`, `mutationEntriesFromInboundSlices` → `AppSync_Adapter` | evaluates the rule for the command type's **first constructor** (`permissionForFirstConstructor`) and stamps that one gate on the mutation field |
| **Local door**: `InboundTranslationResolvers_GraphQL` | **no gate.** The resolver ignores its context (`async (_root, args, _ctx)`), and the inbound resolver hook is not handed the rule, unlike the state change slices' hook |
| **Plugin structure**: `requiredRoles` | the **union** over all constructors, with the comment "as the resolver evaluates the rule" |

The comment above `permissionForFirstConstructor` says that where constructors' rules differ,
"resolver-level enforcement still fires inside the per-slice handler". For an inbound slice it
does not: `receive` checks nothing. It could not anyway, because the AWS payload
(`{__inboundTranslation, fieldName, arguments}`) carries no caller identity.

The inbound spec's `lifecycleState` and `commandTransition` are not read at all.

**What this means today.** The examples' inbound command has one constructor, so on AWS
`ImportProduct` is gated correctly (`AllowRoles([Admin, Merchandiser])`). Locally anyone who can
reach the server can call it, and a test of the gate on the local platform would pass while
proving nothing. A slice whose command has two constructors with different rules is gated, on
AWS, by whichever comes first. It is a defect, not a test gap, and it needs its own plan:
[an-inbound-translation-is-gated-and-encoded-like-a-command.md](../plans/an-inbound-translation-is-gated-and-encoded-like-a-command.md).

### 3.2 Inbound commands are encoded without their schema

The inbound callback encodes each command as
`cmd->JSON.stringifyAny->Option.getOrThrow->JSON.parseOrThrow`
([InboundTranslationSlice_Callback.res](../../reventless/core/src/components/InboundTranslationSlice/InboundTranslationSlice_Callback.res),
the encode loop). This is the runtime representation of the ReScript value, not
`Spec.commandSchema`. The outbound path encodes with the schema (`Util_Sury.toJson`). The two
agree for the plain shapes the examples use. They need not agree for a semantic type, an
option or a custom tag, and the target decodes with its own schema. A scenario that compares
typed values cannot catch this. Encoding with the schema fixes it, and the inbound scenario
layer should round-trip through it ([§4.1](#41-the-scenario-the-slices-contract)).

---

## 4. How they should be tested

Each layer proves one thing, and an author should not need a lower layer to see a higher one
pass.

| Layer | Proves | Runs |
|---|---|---|
| **Scenario** | the slice's contract: this message gives these commands; this event queues this item; this item sends this and, given this answer, asks this | the slice's real `collect`, `translate` and `onExhausted`, with recording fakes |
| **Slice runtime** | statuses, retries, `Abandoned`, audit rows, dedup, recovery | the callbacks with in-memory stores |
| **Flow** | the chain: message in → decision → events → automation → message out | `Flow_GWT` with an inbound step |
| **Door** | who may call, and how the door answers | the generated mutation (and later the webhook) on the local server |

### 4.1 The scenario: the slice's contract

**Inbound.** Take the slice as written (`Make(Spec, Translation)`), and add three verbs:

| Verb | Why |
|---|---|
| `whenReceived(json)` | decodes through `externalInputSchema`, as the door does; a payload the schema refuses becomes a scenario (`thenRefusedInput(reason)`) |
| `thenCommands` encoding through the command schema | compares what the target will decode, not the ReScript value |
| `thenNotUnderstood(msg)` | the author's name for `thenTranslateError`; keep the old name |

`whenInput` stays for typed tests. The recommended material for `whenReceived` is the external
system's own sample payloads, kept as files beside the test. A provider's documented example
then becomes a scenario, and a format change shows up as a failing scenario.

**Outbound.** Take the slice as written, and run its own `translate` with capabilities the
test supplies:

| Verb | Why |
|---|---|
| `givenCapabilities(fakes)` | the fakes; default `Capabilities.none` |
| `whenTranslated` | runs the slice's `translate(id, item, ~capabilities)`, turning a throw into `Error` as the runtime does |
| `thenSent(calls)` / `thenNothingSent` | what the fakes recorded, after `SideEffect_GWT`'s `thenExternalCalls` |
| `whenExhausted(~lastError)` → `thenCommand` / `thenNoCommand` | the give-up handler |
| `thenTodoStatus` with `#Completed \| #Failed \| #Abandoned` | the runtime's words |
| `whenTranslateRetrying(~maxRetries)` | counts attempts as the runtime does |

`whenTranslateMocked` stays as the escape hatch for a slice that calls a client directly, as
SendOrderConfirmation does. The better fix is in the slice: an external call goes through a
capability, so it can be faked. This is the argument
[sideeffect-gwt](../plans/done/sideeffect-gwt.md#the-constraint-sideeffectexecute-has-no-di-seam)
made for side effects, and that
[trait-contact-verification](../plans/trait-contact-verification.md) made for secrets.

**Recording fakes.** Today there are building blocks (`Capabilities.none`,
`Messaging.makeProvider(~send)`, `Secrets.fixed`, `IdentityProvider.unavailable`) and no fakes.
A `Capabilities_Fake` module in the GWT package should provide one per capability, each
recording its calls and answering from a script:
- messaging keeps the sent messages;
- geocode answers per text;
- secrets are fixed;
- the identity provider answers per user.

This is what VerifyCustomerEmail's refs do by hand.

### 4.2 The slice runtime

The fixture suites are good, and they stay. Three additions:
- a crashed attempt left in `Processing` is recovered;
- a successful call followed by a failed publish does not call again, or calls again with the
  same idempotency key. Which one is a decision ([§5](#5-open-questions)), and the test pins
  it;
- the audit row's `targetIds`, `error` and `input`.

### 4.3 The flow

`Flow_GWT` needs:
- an `InboundStep` with `whenReceived(json)`, which publishes the translated commands into the
  flow's log;
- an `OutboundStep` that runs `translate` with fakes and passes the real `sourceId`.

A flow can then state a whole integration: *the supplier sends a product → it is added → it
shows in the catalogue*; or *an order is placed → a confirmation is sent → nothing is sent
twice*.

### 4.4 The door

`InboundTranslationMutationTest` covers the mutation's shape. Once [§3.1](#31-inbound-commandauthorization-is-enforced-only-on-aws-and-only-for-the-first-constructor)
is fixed, it needs a caller without the role, refused, and one with it, accepted, on the local platform as well as in the AWS schema. The webhook
plan already lists its own door tests: signature, replay, both doors giving the same commands
([Tests (step 16)](../plans/Backlog/webhook-infrastructure.md#tests-step-16)).

---

## 5. Open questions

1. **Outbound idempotency: avoid the second call, or make it harmless?** The runtime could
   mark the row *sent* before publishing the answer, or hand `translate` a stable key (the
   to-do id) that providers can deduplicate on. Leaning: both; the key costs nothing, and the
   *sent* mark closes the publish-failure window.
2. **Inbound deduplication.** Deduplicate on a provider key against the audit log, or leave it
   to `translate` returning `Ok([])`? The webhook plan leaves this open too (its open
   question 6). Leaning: an optional `messageKey: externalInput => option<string>` on the
   spec, checked against the audit log.
3. **Should the old flat `Make` stay?** Leaning: yes, deprecated, until the examples have
   moved.
4. **Sample payload files: where, and in what format?** Leaning: `tests/<Slice>/samples/*.json`,
   read by `whenReceived(Sample.file("…"))`.

---

## 6. Decisions to record

| # | Question | Leaning |
|---|---|---|
| D1 | Does an outbound scenario run the slice's own `translate`? | **Yes, with recording fakes; the mock becomes the exception** |
| D2 | DSL statuses and retry budget | **The runtime's: five statuses, `maxRetries` counts attempts** |
| D3 | Does an inbound scenario decode JSON and encode commands through the schemas? | **Yes, with `whenReceived`; `whenInput` stays** |
| D4 | Inbound authorization | **Its own plan; one rule at every door; a defect, not a test gap** |
| D5 | Inbound command encoding | **Through `Spec.commandSchema`, as outbound does** |

---

## 7. Where it is planned

| What | Where |
|---|---|
| DSLs that take the slice as written; the scenario sidecar reads these tests; model sidecars carry the wiring | [plans/the-sidecars-read-automations-and-translations.md](../plans/done/the-sidecars-read-automations-and-translations.md) |
| Recording capability fakes, `whenTranslated`, `thenSent`, `whenExhausted`, statuses and retry budget aligned, `whenReceived`, flow inbound step | the same plan's second phase; the verbs are listed there |
| Inbound authorization the same at every door; commands encoded with their schema | [plans/an-inbound-translation-is-gated-and-encoded-like-a-command.md](../plans/an-inbound-translation-is-gated-and-encoded-like-a-command.md) |
| Idempotency in and out | open ([§5](#5-open-questions)); inbound with [webhook-infrastructure](../plans/Backlog/webhook-infrastructure.md) |
| Stale documentation | `given-when-then.md` §4.8 and §4.9 (the real `translate` is not exercised in component tests); [given-when-then-specifications §2.5](./given-when-then-specifications.md#25-coverage-matrix) ("no DSL"); the OutboundStep claim in [gwt-flow-and-extension-test-kinds](../plans/done/gwt-flow-and-extension-test-kinds.md). Fix when the plan lands |
