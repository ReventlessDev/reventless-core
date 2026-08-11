# One id contract across the query doors and both providers

## Status: ✅ Done

A read-side row is reachable through four id-accepting doors. They disagreed
about which id form they took, and the row's own `id` depended on which door
answered — so the obvious client call `X(id: row.id)` returned `null` with no
error. Resolved by making every typed door **accept either form** and **report
the storage key**, with `node` kept as the one door that speaks Relay global ids
on both sides.

---

## What was measured, before

Against the local hybrid platform, one customer registered as `cust-42`:

| Door | raw storage key | Relay global id |
|---|---|---|
| `Ordering_Customer(id: ID!)` | ✅ row | ❌ `null` |
| `node(id: ID!)` | ❌ `null` | ✅ row |
| `Ordering_CustomersByIds(ids: [String!]!)` | ✅ row | ❌ `[]` |
| `Ordering_Customers(filter: {ids: […]})` | ✅ row | ✅ row |

Four doors, three contracts. `filter.ids` was the outlier that already accepted
either form — the rule existed, implemented once, in the one door nobody trips
over.

### The row's own `id` was not stable

The premise "local advertises the global id, AWS advertises the raw one" turned
out to be half bug. The local `byId` / `ByIds` / `node` resolvers stamped the
Relay id with `obj->Dict.set("id", …)` after `JSON.Decode.object`, which returns
**the stored object itself** — so loading a detail row rewrote the row inside the
QueryDb:

```
list before byId → "id": "cust-88"          (storage key)
byId             → "id": "T3Jk…NDg="        (global id)
list after byId  → "id": "T3Jk…NDg="        (poisoned)
```

The AWS analogue (`withId`) had always copied first. This is the shape of the
real-world failure: a client reads `row.id` from a list, passes it to
`X(id: row.id)`, and gets `null` — a detail panel that opens empty, on local
only, and only after something had already opened that row once.

---

## The decision: the storage key is what a row reports

The open question was what a row's `id` should carry. The deciding input was
whether anything actually uses Relay's `node` for refetch. Checked in the shell:

- **`node(id:)` is used nowhere.** The only `node` selections are Relay
  *connection edges* (`edges { node { … } }`), not the `Node` root field.
- **The generated UI refetches through the typed doors** — the singular query
  field for a detail row, the by-ids field for batched live patches — and keys
  each row by its `id` field, passing that value straight back. That is exactly
  the round trip that was broken.
- **The generated UI does not use Relay's normalized store.** It executes
  dynamically built documents through a plain transport, because read models are
  discovered at runtime and cannot be compiled ahead of time. The strongest
  argument for global ids — a normalized cache keyed by a globally unique id —
  therefore does not apply.
- Relay proper is used only for the platform admin screens, against `Platform_*`
  fields, which are wired with `relay=None` and so never carried global ids.

So global-ids-everywhere would have bought one door nothing calls and a cache
behaviour nothing uses, in exchange for:

- rewriting ~11 generated DynamoDB resolver templates in
  [AppSync_Resolver_Functions](../../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L92),
  which put `ctx.args.id` straight into the table key — decode on every request
  template, encode on every response template, each a deploy-time artifact whose
  mistakes surface only on AWS; and
- changing pagination semantics: [`getCursorValue`](../../../reventless/core/src/components/Api/QueryDbListQuery.res#L218)
  falls back to the row's `id` when no `orderBy` is given, and cursors are
  compared as strings. Base64 is not order-preserving, so making `id` global
  would silently reorder default pages and invalidate every issued cursor.

The storage key also lines a row up with the reference fields that point at it
(`Orders.customerId`), which is what reference resolution works with.

---

## What changed

| File | Change |
|---|---|
| [Api_Ids.res](../../../reventless/core/src/components/Api/Api_Ids.res) | New. The one definition of the global-id encoding, plus `alternateKey` — the storage key inside a global id, or `None`. Provider-neutral: the contract belongs to neither adapter. |
| [QueryDbResolvers_GraphQL.res](../../../reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res) | `byId` and `ByIds` retry with `alternateKey` on a miss, report the storage key they resolved to, and `Dict.copy` before stamping so the stored row is left alone. `node` keeps its Relay contract, now stated in a comment. |
| [PgQueryResolver_Lambda.res](../../../reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res) | Same either-form rule for `getById` and `byIds`. The second lookup only runs when the first came up short. |
| [QueryDbListQuery.res](../../../reventless/core/src/components/Api/QueryDbListQuery.res) | `passIds` decodes **both** sides — it decoded only the row's id, which stopped matching once rows carried storage keys. `decodeLocalId` now defaults to the shared rule, so the AWS Lambda stops passing a no-op that made `filter.ids` reject a global id on that provider alone. |
| [DomainGraphQL_Server.res](../../../reventless/local/src/adapter/DomainGraphQL_Server.res) | `encodeGlobalId` / `decodeGlobalId` become thin re-exports of the shared helper. |

**Why the raw key is tried first and the decode is only a fallback:** a storage
key that happens to be valid base64 must keep resolving to its own row. Decoding
up front would silently rewrite it into something that matches nothing.

---

## Validated

Live, against the local hybrid platform:

| | reports | accepts storage key | accepts global id |
|---|---|---|---|
| list `edges.node.id` | storage key | — | — |
| `X(id:)` | storage key | ✅ | ✅ |
| `XsByIds(ids:)` | storage key | ✅ | ✅ |
| `Xs(filter: {ids:})` | storage key | ✅ | ✅ |
| `node(id:)` | global id | — | ✅ |

And the round trip that started this: read `row.id` off a list, pass it to
`X(id:)`, get the row. Listing a row after opening its detail no longer changes
its `id`.

Tests: `Api_IdsTest` (encode/decode edge cases, the copy-before-stamp rule, and
`filter.ids` in both directions) and a door × id-form matrix on the AWS
dispatcher in `PgQueryResolver_LambdaTest`, which is unit-testable against an
in-memory mock. Full suite green.

**Not covered:** the AWS side is exercised through the dispatcher's unit tests,
not against a deployment. Its DynamoDB resolver templates were left untouched —
they already report the storage key, which is now the stated contract.

**Commit.** `fix(api): one id contract across the read-side query doors`
