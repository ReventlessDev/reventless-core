# Plan: Give InboundTranslationSlice mutations a resolvable result type

**Status:** Complete (2026-07-24)
**Origin:** [online-shop-hybrid-demo-data.md](online-shop-hybrid-demo-data.md) — found while seeding the hybrid example; the seeder carries a carve-out for this exact error and this plan deletes it.
**Follow-up filed:** [aws-inbound-translation-lambda-routing.md](../Backlog/aws-inbound-translation-lambda-routing.md) — the AWS-parity check below found these mutations are not routed at all on AWS.

Every InboundTranslationSlice mutation on the local platform returns a GraphQL
error even when the translation succeeds:

```
Abstract type "CommandResult" must resolve to an Object type at runtime for field Mutation.Catalog_ImportProduct
```

The command is published, the events are appended and the slice's audit view
records `Success` — only the *response* is unusable. Any client that checks for
`errors` (which the seeder does, and which a generated client would) sees a
failed call.

---

## Motivation

The SDL and the resolver disagree about the field's return type.

**SDL side.** [`GraphQL_FragmentGenerator.res:374`](../../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L374) —
`deriveMutationFieldFromObject` hardcodes the return type:

```rescript
Some(`  ${fieldName}${argsPart}: CommandResult!`)
```

It is the shared mutation-field deriver, written for aggregate and
StateChangeSlice commands where `CommandResult` is exactly right.
[`InboundTranslationResolvers_GraphQL.res:27-35`](../../../reventless/local/src/adapter/CommandGenerator/InboundTranslationResolvers_GraphQL.res#L27-L35)
reuses it and inherits the return type.

**Resolver side.** [`InboundTranslationResolvers_GraphQL.res:48-56`](../../../reventless/local/src/adapter/CommandGenerator/InboundTranslationResolvers_GraphQL.res#L48-L56)
returns a value with no `__typename`, so graphql-yoga cannot resolve the union:

```rescript
switch result {
| Ok(targetIds) => targetIds->Array.map(JSON.Encode.string)->JSON.Encode.array
| Error(msg) => msg->JSON.Encode.string
}
```

Compare the command path, which encodes an explicit `__typename` for exactly
this reason — [`CommandTopic_Helpers.commandOutcomeToJson:49`](../../../reventless/core/src/components/CommandTopic/CommandTopic_Helpers.res#L49),
shared with the AWS Lambda entry point so both surfaces stay byte-compatible.

The mismatch is structural, not incidental: `Ok(targetIds)` is an
`array<string>` and can never satisfy `CommandResult`, so **every**
InboundTranslationSlice mutation is affected on every plugin — the hybrid
example's `Catalog_ImportProduct` is just the one that got exercised.

The fallback branch has the same class of bug: when
`deriveMutationFieldFromObject` returns `None` the field is typed `String!`
([line 34](../../../reventless/local/src/adapter/CommandGenerator/InboundTranslationResolvers_GraphQL.res#L34)),
which the `Ok` branch's array also violates.

### Why it went unnoticed

There is no test that executes an InboundTranslationSlice mutation through a
running platform. The slice has callback-level coverage, and the SDL is
asserted structurally, but nothing runs the field and inspects the response
envelope. The demo seeder was the first caller to check `errors`.

## Decision

**Keep `CommandResult` and make the resolver produce a valid member of it.**

An inbound translation can publish N commands across N targets, so a union
purpose-built for translations (`TranslationAccepted { requestId, targetIds,
commandCount }` / `TranslationRejected`) would describe the component more
honestly. That is deliberately *not* the choice here:

- it is a new public SDL type, which lands as UI work in the host shell (its
  command-form handling knows `CommandAccepted` / `CommandRejected`);
- the per-target detail is already queryable — the slice's audit read model
  records `targetIds`, `commandCount` and `status` per request;
- `CommandResult` already has the two outcomes callers branch on.

If a later consumer genuinely needs the fan-out in the mutation response, the
seam is a `~returnType: string="CommandResult!"` parameter on
`deriveMutationFieldFromObject` — additive, and every existing caller keeps the
default. Noted, not built.

Mapping:

| `receive` result | GraphQL response |
|---|---|
| `Ok(targetIds)` | `CommandAccepted { msgId: requestId, entityId: first targetId or null, eventCount: commandCount }` |
| `Error(msg)` | `CommandRejected { msgId: requestId, errorCode: "TranslationFailed", errorDetail: msg }` |

`entityId` is nullable in the SDL, so an empty `targetIds` (a translation that
legitimately produces no command — see
[`InboundTranslationSlice_Callback.res`](../../../reventless/core/src/components/InboundTranslationSlice/InboundTranslationSlice_Callback.res),
the `pairs->Array.length === 0` branch) encodes as `null` rather than a lie.

## Steps

1. **Widen the `receive` result so the resolver can fill `CommandResult`.**
   Today it is `result<array<string>, string>` and carries neither the
   `requestId` nor the command count, both of which the callback already
   computes. Introduce a small record — `{requestId: string, targetIds:
   array<string>, commandCount: int}` on the `Ok` side, `{requestId: string,
   error: string}` on the `Error` side — and thread it through:
   - [`InboundTranslationSlice_Callback.res:29-32`](../../../reventless/core/src/components/InboundTranslationSlice/InboundTranslationSlice_Callback.res#L29-L32) (module type `T`) and the `receive` body below it — all four early-return sites already have `requestId` in scope;
   - [`InboundTranslationSlice.res:18`](../../../reventless/infra/src/components/InboundTranslationSlice.res#L18) (`operations.receive`);
   - [`Plugin_Helpers.res:935`](../../../reventless/core/src/plugin/component/Plugin_Helpers.res#L935) (`inboundMutationBindReceiveHook`);
   - [`InboundTranslationResolvers_GraphQL.res`](../../../reventless/local/src/adapter/CommandGenerator/InboundTranslationResolvers_GraphQL.res) — `receiveRegistry`, `pendingCall`, `bindReceive`.
2. **Encode a `CommandResult` in the resolver.** Replace the `switch result` at
   [lines 52-55](../../../reventless/local/src/adapter/CommandGenerator/InboundTranslationResolvers_GraphQL.res#L52-L55)
   with a `CommandTopic.commandOutcomeToJson` call built from the record above,
   so the inbound path reuses the same encoder as the command path rather than
   hand-rolling a second `__typename` writer.
3. **Register the union types on the inbound path.** `register` currently never
   calls `ensureCommandResultTypes`; it works today only because a plugin with
   command handlers registers them first. Call
   [`CommandGeneratorResolvers_GraphQL.ensureCommandResultTypes`](../../../reventless/local/src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res#L110)
   in `register` — `registerTypes` dedupes identical blocks, so a plugin whose
   only mutation is an inbound translation stops depending on registration
   order.
4. **Fix the `None` fallback** at
   [line 34](../../../reventless/local/src/adapter/CommandGenerator/InboundTranslationResolvers_GraphQL.res#L34)
   to emit `: CommandResult!` instead of `: String!`.
5. **Delete the seeder carve-out.** `DemoSeed.res` in
   `examples/online-shop-hybrid/platform-local/src/` swallows this exact error
   string and verifies the import through the audit view instead. Remove the
   carve-out and let the mutation be checked like every other one.
6. **Cover it.** Add a local-platform test that executes an
   InboundTranslationSlice mutation end to end and asserts (a) no `errors` in
   the response envelope, (b) `__typename == "CommandAccepted"` with the
   expected `entityId`, and (c) a rejection path yielding `CommandRejected`.
   This is the gap that let the bug ship — a callback-level test cannot see it.

## AWS parity — answered

**They are not routed on AWS.** The marker is read in one place —
[`Dcb_Builder.res:707-741`](../../../reventless/core/src/components/Dcb/Dcb_Builder.res#L707-L741),
the in-process composite handler, which this plan updated alongside the local
resolver — but that handler is built at deploy time from resolved Pulumi Outputs
and is not what the deployed Lambda runs. The deployed entry point
[`DcbCommandTopicEntryPoint.mjs:206`](../../../reventless/aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs#L206)
has two routes, and an `__inboundTranslation` payload matches neither: Route 1
guards on `event.command != null`, which the payload does not carry, and Route 2
reads `event.Records`, which it also does not carry. The mutation returns `""`
and nothing happens.

Filed separately as
[aws-inbound-translation-lambda-routing.md](../Backlog/aws-inbound-translation-lambda-routing.md).
The SDL and encoder work here is a prerequisite for it, not a duplicate of it:
the AWS route, once added, encodes its outcome with the same
`receiveResultToOutcome` → `commandOutcomeToJson` pair introduced below.

## Outcome

Delivered as planned, with two notes.

**The shared encoder landed in core, not in the local adapter.** Step 2 asked
the resolver to call `CommandTopic.commandOutcomeToJson`; the mapping from a
`receive` outcome to a `commandOutcome` is needed by the in-process composite
handler too, so it lives in
[`InboundTranslationSlice.receiveResultToOutcome`](../../../reventless/core/src/components/InboundTranslationSlice/InboundTranslationSlice.res)
and both call sites pipe through it. The AWS route in the follow-up gets it for
free.

**The result types live in `reventless-infra`**
([`InboundTranslationSlice.res`](../../../reventless/infra/src/components/InboundTranslationSlice.res))
as `acceptedResult` / `rejectedResult` / `receiveResult`, matching
`CommandTopic_Helpers`' naming — `operations.receive` is declared there, so the
types have to sit at or below it.

Step 5 removed `Seed_Client.sendInboundTranslation` outright: with the field
reporting its own outcome, `send(~tolerate=["TranslationFailed"])` covers the
seeder's deliberately-invalid feed row, and the audit-view cross-check stays as
a second signal rather than the only one.

Step 6 landed as
[`InboundTranslationMutationTest.res`](../../../reventless/local/tests/adapter/InboundTranslationMutationTest.res).
It composes the schema through `DomainGraphQL_Server.composeSchema` and executes
a document against it, so it sees the whole envelope. Reverting the resolver to
the old array encoding makes both execution cases fail with the exact reported
error, which is the check that matters — a resolver-level test passes either way.
Executing in-process needed a `graphql` binding, added to
[`GraphqlYoga.res`](../../../rescript/graphql-yoga/src/GraphqlYoga.res) next to the
existing `printSchema` (also a `@module("graphql")` re-export).

Registering the slice in a *plugin* scope rather than the platform one makes the
test cover step 3 as well: a plugin bucket's document is validated standalone
before the cross-plugin merge, so without `ensureCommandResultTypes` the schema
fails to build at all.

## Acceptance

- ✅ A successful translation returns `data` with no `errors` and resolves as
  `CommandAccepted`, carrying the first target as `entityId` and the fan-out as
  `eventCount`.
- ✅ A deliberately invalid input yields `CommandRejected` with `errorCode:
  "TranslationFailed"` and the translation error in `errorDetail`; the audit row
  still records `Failure`.
- ✅ The seeder runs with no carve-out.
- ✅ New local-platform test green; full suite green (191 suites / 1417 tests);
  zero build warnings.

Verified live against the running hybrid platform, seeding from an empty store
(`serve:reset` + `demo-data`), and reproduced on a second wipe-and-reseed:

```
supplier feed: 4 imported, 1 rejected (both shown in the audit view)
```

That line carries both acceptance cases, because every import now goes through
`Seed.Client.send`, which aborts on any `errors` in the envelope and on any
untolerated rejection. The four valid rows therefore resolved as
`CommandAccepted`, and the deliberately-invalid row as `CommandRejected` with
`errorCode: "TranslationFailed"` — any other code would have failed the run
rather than matched `~tolerate`. The audit view agrees with the payloads: four
`Success` rows with `commandCount: 1` and a single `targetIds` entry (the SKU
returned as `entityId`), one `Failure`. The server log carries no occurrence of
the `Abstract type "CommandResult"` error that motivated the plan.

## Risks — as resolved

- **Response-shape change for any existing consumer.** Only two callers existed:
  the seeder's carve-out (deleted) and the in-process composite handler (updated).
  Nothing consumed the array shape successfully, because it never validated.
- **Touching `receive`'s signature ripples through four modules.** It reached
  five — the composite handler in `Dcb_Builder` was not on the list. The compiler
  found it, as expected.
