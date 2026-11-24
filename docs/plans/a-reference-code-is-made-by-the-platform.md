# Plan: a reference code is made by the platform, shown, and found by its value

> **Status:** 🔨 In progress, 2026-11-24: [RCC1 to RCC8](#4-steps) being built, not committed.
> Where the build differs from the steps:
> - the type takes any text exactly as it is; it does not trim or upper-case
>   ([RCCD7](#3-decisions)), since a sury transform hides a schema's shape from the JSON Schema and
>   the API, and the kit's Paste trims;
> - the semantic is a branded string (`Semantic.brandedStrings`, and the ppx's copy of that list),
>   not a value type, since its value is a plain string;
> - the spec writes `@issued` and `@dcbTag` on a `ReferenceCode.t` field ([RCC8](#4-steps)); the
>   schemas behind them are `ReferenceCode.issued` and `ReferenceCode.tag`.
> - [RCC4](#4-steps) is pinned by the spec's `ReferenceCodeTest` (a tagged field is a tag keyed by
>   its name) and the ppx's fixture, not by a GWT of a presenting command: the shop has none;
> - [RCC7](#4-steps): the shop's `PlaceOrder` has `@issued reference?`, `OrderPlaced` carries it
>   with `@dcbTag`, and the orders view shows it; optional, so earlier events, tests and seed data
>   stay valid, while the write path always fills it. A scenario pins the event;
> - the stamp's tests are `ReferenceCodeStampingTest`, with the JSON Schema's two keys; the ppx's
>   vocabulary lists `issued`.
>
> **Questions and short answers:**
>
> 1. *What is a reference code?* **A short code the platform makes, which a person reads, copies
>    or types back, and which finds one record.** A booking reference, the token a charger knows a
>    customer by, an order number read out on the phone. It is not a secret: it is shown, and
>    stored as it is ([§1](#1-in-plain-words)).
> 2. *How is it written in a spec?* **`Reventless.ReferenceCode.t` wherever the value travels**: in
>    the command that presents it, the event that records it, the view that shows it. **On the one
>    command field the platform fills, `@s.matches(Reventless.ReferenceCode.issued)`**
>    ([RCCD1](#3-decisions), [RCC2](#4-steps)).
> 3. *Where is the value made?* **On the command path, before the handler, from the deployment's
>    `Secrets` source.** The decision stays a function of its input, the event records the value,
>    and a replay gives the same state ([RCCD2](#3-decisions), [RCC3](#4-steps)).
> 4. *Can a caller choose the code?* **No: a value a caller sends is replaced.** An exempt caller
>    (the platform's own traffic, an operator) keeps a value it sends, which is how example data
>    and migrations carry codes of their own ([RCCD3](#3-decisions)).
> 5. *How is a presented code checked?* **By looking it up, not by cryptography.** The event that
>    issued it is tagged by the code; the decision of a command that presents a code reads by that
>    tag and refuses a code it does not find ([RCC4](#4-steps)).
> 6. *Why not call it a token?* **In core a token is secret material (`Secrets.randomToken`), and
>    in authentication a credential**; this value is neither ([RCCD4](#3-decisions)).
> 7. *Can another way of making codes be used later?* **Yes: the code is drawn from the `Secrets`
>    port**, whose adapter a platform chooses. Core's node adapter is the first; a service that
>    issues codes is another adapter ([RCCD5](#3-decisions), [RCCQ2](#5-open-questions)).
> 8. *What about a code that proves something, such as a confirmation code?* **That stays a
>    secret**, hashed with `Secrets.hash` as contact verification does
>    ([§7](#7-out-of-scope)).
>
> **Relates to:** the usage docs,
> [ui-configuration.md §2.7](../../packages/doc/docs-app/ui-configuration.md#27-semantics--what-a-value-is)
> ([RCC6](#4-steps)) · the owner stamp this mirrors,
> [owner-scoped-identity-and-reads.md](done/owner-scoped-identity-and-reads.md) · the `Secrets`
> port, `reventless/spec/src/semantic/Secrets.res`.
>
> **Ids:** `RCCD` (reference code, core, decision) in [§3](#3-decisions), `RCC` (step) in
> [§4](#4-steps), `RCCQ` (question) in [§5](#5-open-questions).

---

## 1. In plain words

Many apps hand a person a code: a booking reference, a member number, the token a charger knows
a customer by. The person reads it off a screen, copies it, prints it on a card or types it into
a device, and the app finds the record by it. Three things make such a code work:

- **Nobody chooses it.** If a caller could pick it, they could pick a guessable one, or someone
  else's. The platform makes it at random.
- **It is made once.** The event that records it carries the value, so every replay and every
  reader sees the same code.
- **It is found by its value.** A command that presents the code reads the record it belongs to,
  and refuses a code nothing has.

This plan adds a semantic type for such a code, `ReferenceCode`, and a marker for the command
field the platform fills, `ReferenceCode.issued`. It reuses two things core has: the owner stamp's
place on the command path, and the `Secrets` port as the source of randomness.

## 2. What there is today

- **The owner stamp.** `CommandGenerator_Callback.stampOwnerFields` overwrites every
  `Owner`-marked field of the command being issued with the caller's id, in the one function every
  transport's payload passes through. An exempt caller is left alone; an unidentified one is
  refused. A reference code needs the same place and the same overwrite rule.
- **The `Secrets` port.** `Secrets.t` (`reventless/spec/src/semantic/Secrets.res`) gives
  `randomToken(~length, ~alphabet)` from `Digits` or `UrlSafe`. A platform injects its adapter
  through `Capabilities.secrets`; both platforms pass `Secrets_Node_Backend.provider`, and a test
  passes `Secrets.fixed`. `makeGenerateCommand` is not handed the capabilities.
- **Semantic types.** `Percent`, `Money`, `Energy` and the others carry
  `x-reventless-semantic` into the JSON Schema, and readers draw a field by it.
- **Finding by a value.** A field typed by an identity (`CustomerId.t`) composes with a DCB tag
  ([the ppx docs](../../packages/doc/docs-app/reventless-ppx.md)), so a decision reads every event
  tagged with that value. A semantic string type does not compose that way yet.
- **Values a client makes.** The UI kit makes one value itself: a new thing's id, a UUID. Nothing
  else a command needs is made by anyone but the caller.

## 3. Decisions

| # | Decision | Why |
|---|---|---|
| **RCCD1** | A **type** says what the value is (`ReferenceCode.t`), and a **marker** says where it is made (`ReferenceCode.issued`, on one command field) | The value travels through commands, events and views; only one place makes it, as only one place stamps an owner |
| **RCCD2** | The code is made on the command path before the handler and carried in the command | `decide` must not draw randomness, and a projection would make a new code on every replay |
| **RCCD3** | The issued field is overwritten for every caller but an exempt one, which keeps a non-empty value it sends and gets a new code when it sends none | A caller who picks the code must get the same result as one who sends none; example data and migrations need their own codes |
| **RCCD4** | The name is `ReferenceCode` | `Token` means secret material in `Secrets` and a credential in authentication; a booking reference is the closest thing everyone knows |
| **RCCD5** | The code is drawn from the `Secrets` port with a new alphabet, `Readable`; a source that cannot draw refuses the command | The port already has adapters per platform and a fixed one for tests; a weaker fallback would be accepted everywhere |
| **RCCD6** | A made code is twelve characters of `Readable` (digits and capitals without `0`, `O`, `1`, `I`) in groups of four, `7KQ3-X9MD-4TPA`: 60 bits | Short enough to read out and type, and no character looks like another |
| **RCCD7** | The type accepts any text, exactly as it is | Codes from example data, a migration or another system keep their own shape |

## 4. Steps

| Step | What | Size |
|---|---|---|
| RCC1 | Rename the first cut: `Generated` becomes `ReferenceCode.issued`, `x-reventless-generated` becomes `x-reventless-issued` | S |
| RCC2 | The type `ReferenceCode.t`: its schema, the semantic `referenceCode`, its value type | S |
| RCC3 | The command path fills an issued field from `Secrets` | S |
| RCC4 | A code finds its record: a DCB tag composes onto `ReferenceCode.t` | S–M |
| RCC5 | The API lets a caller leave an issued field out | S |
| RCC6 | The docs: how to use it | S |
| RCC7 | An open example uses it | S |
| RCC8 | The ppx: `@issued`, and `@dcbTag` on a field typed by a semantic string | S–M |

**RCC1. The first cut renamed.** The working tree's `spec/src/components/Generated.res` becomes
`spec/src/semantic/ReferenceCode.res`, beside the other semantic types. Its marker functions
(`isFieldIssued`, `fieldNames`, `variantFieldNames`) stay as they are, renamed. The code's length
and grouping move with it (`ReferenceCode.length`, `ReferenceCode.grouped`).

**RCC2. The type.** `ReferenceCode.t = string`, and `ReferenceCode.schema` parses any text,
trimmed and upper-cased, and carries the semantic `referenceCode` (registered in `Semantic` as
`Percent` is). `ReferenceCode.issued` is that schema with the issued marker. `Semantic.valueTypes`
gains its entry (a string), so a tool that writes a scenario's value knows how.

```rescript
// The command that makes it
SignUp({@partitionTag driverId: string, @issued chargingToken: Reventless.ReferenceCode.t})
// The event that records it, and the command that presents it
DriverSignedUp({driverId: string, @dcbTag chargingToken: Reventless.ReferenceCode.t})
StartSession({@partitionTag sessionId: string, chargingToken: Reventless.ReferenceCode.t})
```

**RCC3. The command path.** `stampIssuedFields` runs after `stampOwnerFields` in
`makeGenerateCommand`, as the first cut does: for each issued field of the command being issued
it draws `Secrets.randomToken(~length=12, ~alphabet=Readable)` and writes it grouped, unless the
caller is exempt and sent a non-empty value. `makeGenerateCommand` takes `~secrets`, defaulting to
`Secrets_Node_Backend.provider` ([RCCQ2](#5-open-questions)). `Secrets.alphabet` gains
`Readable`; the node adapter's unbiased draw serves it unchanged.

**RCC4. A code finds its record.** `@dcbTag("key")` on a field typed `ReferenceCode.t` composes
the tag onto `ReferenceCode.schema`, as it does onto an identity's schema, so the field keeps its
semantic. A decision of a command that presents a code then reads the events tagged with it. A GWT
example in the spec's tests shows the whole case: the issuing event tagged, a presenting command
accepted for a known code and refused for an unknown one.

**RCC5. The API.** An issued field is an optional mutation argument (`String`, not `String!`),
in `deriveMutationFieldFromObject` and `mutationArgTypes` alike. In the JSON Schema it carries
`x-reventless-semantic: "referenceCode"` and `x-reventless-issued: true`, and is left out of
`required`, so a form asks nothing for it. Every other field of the type carries the semantic only.

**RCC6. The docs.** [ui-configuration.md §2.7](../../packages/doc/docs-app/ui-configuration.md#a-reference-code)
gains *A reference code*: the type, the marker, where the value is made, who may send one, and
finding a record by it. `ReferenceCode` joins the list of semantic types there.

**RCC7. An open example.** The hybrid online shop's order gets an order reference the customer
sees and reads out, and customer service finds the order by it
([RCCQ5](#5-open-questions)).

**RCC8. The ppx writes the markers.** A spec says `@issued chargingToken:
Reventless.ReferenceCode.t` on the making command, and `@dcbTag chargingToken:
Reventless.ReferenceCode.t` on the event it is found by:
- **`@issued`** becomes `@s.matches(Reventless.ReferenceCode.issued)`. Like `@owner` it runs after
  the tag passes and wraps a schema the field already has (`ReferenceCode.markIssued(<schema>)`);
  on a field not typed `ReferenceCode.t` it is a compile error.
- **`@dcbTag` on a field typed by a semantic string** (`ReferenceCode.t`, `Email.t` and the others
  with a schema named by convention) puts the tag onto that schema,
  `DcbTag.markDeclared(Reventless.ReferenceCode.schema)`, as it does onto an identity's. Before
  this, such a field kept the attribute and was not tagged, with no error.

The ppx's test fixtures pin both. The ppx is released in step with core, as for every pass.

**Tests.** `ReferenceCodeTest` (spec): the schema trims and upper-cases, the markers are found on
a variant and through an optional field. `ReferenceCodeStampingTest` (core, from the first cut's
`GeneratedStampingTest`): an omitted field filled, a sent one replaced, an anonymous caller's
command filled, two commands given two codes, an exempt caller's value kept and filled when
absent, a command without the marker untouched, a pinned `Secrets.fixed` source giving the grouped
code, an unavailable source refusing the command; the optional argument and the JSON Schema marks.
The GWT example of [RCC4](#4-steps).

## 5. Open questions

Numbered **RCCQ1 to RCCQ5**, each with a recommendation.

**RCCQ1. Should the ppx get a shorthand `@issued`, as `@owner` has?** **Settled 2026-11-24: yes**,
with `@dcbTag` on a semantic string ([RCC8](#4-steps)). Every app with a code writes both, and
`@dcbTag` on such a field was silently ignored before.

**RCCQ2. Should `makeGenerateCommand` be handed the platform's `Capabilities.secrets`?** Six
places construct it. **Recommendation: not yet**: default to the node adapter, which both
platforms use anyway, and take `~secrets` so a test pins it. Thread the platform's own when a
deployment wants another source.

**RCCQ3. Should a presented code be compared loosely, ignoring spaces and dashes?**
**Recommendation: no**: trim and upper-case only ([RCCD7](#3-decisions)). Dropping separators
would change codes that carry their own (`AMP-0001`), and the UI kit pastes a code exactly. Revisit
if people type codes by hand and miss.

**RCCQ4. Should the platform check a made code is not already taken?** At 60 bits, a million codes
collide with a chance of about four in ten million. **Recommendation: no check.** Revisit if an
app issues codes by the billion or wants shorter ones.

**RCCQ5. Which open example carries it?** **Recommendation: the hybrid shop's order reference**
([RCC7](#4-steps)): a customer reading an order's reference out on the phone is a case everyone
knows, and it makes the shop exercise the stamp, the tag and the docs.

## 6. Verification

- The tests of [§4](#4-steps) pass, with the owner stamp's tests unchanged.
- The full suite and `pnpm run test:projects` stay green; a spec with no reference code emits the
  same SDL and JSON Schema as before.
- In the hybrid shop on the local platform, placing an order shows its reference; finding the order
  by the reference works, and an unknown reference is refused.

## 7. Out of scope

- **A code that proves something** (a confirmation code, a reset link): a secret, hashed with
  `Secrets.hash` and compared by digest, as contact verification does.
- **Replacing a lost code**: a domain command whose field is marked issued again; nothing more in
  core.
- **Codes an outside issuer makes**: sent by an exempt caller, or typed `ReferenceCode.t` without
  the marker.
- **How a reader draws or asks for a code** (Copy, Paste, a QR code): the UI kit's.
