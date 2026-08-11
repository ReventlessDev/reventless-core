# Backlog: One id contract across the query doors and both providers

## Status: 🗄 Backlog

A read-side row is reachable through four id-accepting doors. They disagree about
which id form they take, and the two platform adapters disagree about which form
a row advertises — so the same client query returns a row locally and `null` on
AWS, or the reverse. Nothing errors; the client just gets nothing back.

---

## Measured

Against the local hybrid platform, one customer registered as `cust-42`, whose
row advertises `id: "T3JkZXJpbmdfQ3VzdG9tZXI6Y3VzdC00Mg=="` — that is
`btoa("Ordering_Customer:cust-42")`.

| Door | raw local id | Relay global id |
|---|---|---|
| `Ordering_Customer(id: ID!)` | ✅ row | ❌ `null` |
| `node(id: ID!)` | ❌ `null` | ✅ row |
| `Ordering_CustomersByIds(ids: [String!]!)` | ✅ row | ❌ `[]` |
| `Ordering_Customers(filter: {ids: […]})` | ✅ row | ✅ row |

Four doors, three contracts. The re-fetch itself is not broken — Relay's own
answer, `node(id: row.id)`, works. What breaks is the obvious thing a client
writes: `Ordering_Customer(id: row.id)` silently yields `null`, because the typed
door takes the raw id and the row advertises the global one.

`filter.ids` is the outlier that already does the right thing:

```rescript
// QueryDbListQuery.res — passIds
idList->Array.some(i => i == itemId || itemLocalId == Some(i))
```

It accepts either form. The rule exists; it is just implemented once, in the one
door nobody trips over.

## The provider divergence

The two adapters disagree about what a row's `id` even is:

- **Local** encodes it:
  [`obj->Dict.set("id", encodeId(~typeName, ~localId))`](../../../reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res#L203),
  via `btoa("<Type>:<localId>")` in
  [DomainGraphQL_Server](../../../reventless/local/src/adapter/DomainGraphQL_Server.res#L263).
- **AWS** does not: [`copy->Dict.set("id", JSON.Encode.string(id))`](../../../reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res#L113)
  — the raw id. There is no `encodeGlobalId` equivalent anywhere in
  `reventless/aws`, and the `handleNode` comment says so outright: *"getById
  returns raw ids, so no encoding elsewhere is affected."* Its
  [`handleNode`](../../../reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res#L327)
  still expects a base64 global id — one nothing on that provider emits.

So on local, `X(id: row.id)` fails and `node(id: row.id)` works; on AWS it is the
other way round. A UI built against `pnpm run serve` and deployed to AWS changes
behaviour with no code change and no error — the failure mode is an empty
detail page.

(The AWS side is read from source, not measured against a deployment. Confirm
with an integration run before building on it.)

---

## Goal

One stated id contract: every id-accepting door takes either form, and both
providers advertise the same form on a row. A client that reads `id` off a row
and passes it to any of the four doors gets that row, on either provider.

---

## The decision to make first

**What does a row's `id` carry?** The rest follows from it.

| Option | For | Against |
|---|---|---|
| **Global id everywhere** (local's current behaviour; AWS changes) | The shared SDL already emits `implements Node` and a `node(id: ID!)` root field for both providers. With raw ids, `node` is unusable unless the client hand-builds the base64 — which is what AWS is like today. Relay clients get the contract they expect. | Changes every AWS row payload. Any consumer storing `id` (deep links, caches) sees a new value; needs a redeploy and an AutoUI check. |
| **Raw id everywhere** (AWS's current behaviour; local changes) | Smaller blast radius on the deployed side; a row's `id` matches the key the write side used, so it correlates with `Orders.customerId` directly. | Leaves `node(id:)` decorative on both providers, or forces it to accept raw ids and lose the type prefix that makes it resolvable at all. |

**Recommended: global id everywhere**, because the `Node` interface and the
`node` field are already in the emitted schema for both providers — raw ids make
a shipped part of the schema unusable. The correlation argument for raw ids is
better served by a queryable carrying its own key field, which is what
[queryable-key-field-inference](../queryable-key-field-inference.md) does.

Then, regardless of that choice: **every typed door accepts both forms**, by the
rule `filter.ids` already uses — decode if it decodes to `<Type>:<localId>`,
otherwise treat it as a raw id. Accepting both is what keeps existing callers
(and every hand-written integration test) working through the change.

---

## Sketch of the work

| File | Change |
|---|---|
| new, in `reventless/core/src/components/Api/` | One helper — `Api_Ids` — holding both directions (`encode(~typeName, ~localId)`, `toLocalId(id)`), so the rule lives in one place instead of three. Provider-neutral name and location: the contract is not AWS's or local's. |
| [QueryDbResolvers_GraphQL.res](../../../reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res#L191) | `byIdResolver` and the `ByIds` resolver run the arg through `toLocalId` before `ops.loadStream` / lookup. |
| [PgQueryResolver_Lambda.res](../../../reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res#L113) | Same for the `get` / `byIds` cases; and, if the global-id option is taken, encode the row `id` here and in the AppSync resolver templates that build items. |
| [DomainGraphQL_Server.res](../../../reventless/local/src/adapter/DomainGraphQL_Server.res#L263) | `encodeGlobalId` / `decodeGlobalId` become thin re-exports of the shared helper. |
| [QueryDbListQuery.res](../../../reventless/core/src/components/Api/QueryDbListQuery.res#L148) | `passIds` uses the shared helper; behaviour unchanged — it is the reference implementation. |

**Tests.** A door × id-form matrix asserting the same table for both backends,
in the style of
[QueryDbListPushdownParityTest](../../../reventless/local/tests/adapter/QueryDbListPushdownParityTest.res)
— the parity idea is already established there, this extends it from list
push-down to id handling.

**Validation.** Re-run the matrix above against a local platform: all eight cells
return the row. Then the AWS integration suite for the same four doors.

**Compatibility.** Accepting both forms is purely additive — no existing call
stops working. Changing what a row *advertises* is not: pick the option, and if
it is the global id, treat AWS row payloads as changed (redeploy, AutoUI check,
and anything persisting an `id`).

---

## Why this is Backlog and not blocking

Every door works today if the caller knows which id form it wants. The cost is
paid by a client that mixes doors, or moves between providers — real, but not
blocking any current work, and the fix is a contract decision that deserves its
own slot rather than being smuggled into a schema-derivation change.
