# Plan: an empty DCB tag value must not break the append

**Status**: Done (2026-07-22) — D1/D2/D3 implemented, D4 deferred as planned.
**Nature**: bug fix in one storage adapter, plus a conformance case so the other backends are held
to the same contract. Additive and backward compatible — no schema change, no migration, no
re-provisioning.
**Touches**: `reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res`
(the item builder), the conformance kit, and the `@compositePartitionTag` documentation.

## Motivation

A DCB tag whose value is the empty string makes the DynamoDB append fail outright:

```
DCB append failed: One or more parameter values are not valid.
A value specified for a secondary index key is not supported.
The AttributeValue for a key attribute cannot contain an empty string value.
IndexName: tag_<key>, IndexKey: tag_<key>
```

The append retries three times and gives up. The event is never written.

**The same command succeeds on the in-memory and SQLite backends.** `DcbEventLogStorage_InMemory`
indexes tags into a dict keyed by `tagPostingKey(key, value)`, and `DcbEventLogStorage_Sqlite`
stores them as `dcb_tag` rows matched with `tag_value = ?` — an empty string is an ordinary value
to both. So whether a write succeeds depends on which backend is underneath, which is exactly what
the adapter seam exists to prevent. A model that passes its GWT suites and runs locally fails only
once it reaches DynamoDB.

### Why empty tag values are legitimate

`@compositePartitionTag` builds a partition key from several fields, and the docs are explicit that
"each annotated field is still a regular DCB tag (individually queryable)". Composite keys of that
shape routinely describe a *hierarchy*, and a member of that hierarchy is genuinely absent at some
levels — an entity owned at the outer level has no inner-level name to give. Forcing a placeholder
value there fabricates identity the model deliberately does not have.

So the framework should accept an empty tag value. It is the indexing that must adapt, not the
model.

## Where it breaks

`DcbEventLogStorage_DynamoDb_Runtime.res` writes every tag as its own attribute, unconditionally:

```rescript
// Add individual tag attributes for GSI queries
event.tags->Array.forEach(tag => {
  let attrName = tagToAttributeName(tag.key)   // `tag_${tag.key}`
  item->Dict.set(attrName, tag.value->JSON.Encode.string)
})
```

`DcbEventLogStorage_DynamoDb.res` provisions one GSI per tag key with `hashKey: indexName` — so
that attribute *is* a key attribute, and DynamoDB rejects an empty string for it. There is no
empty-value guard anywhere in the adapter.

## Decision — skip the attribute, keep the event

**When a tag's value is empty, do not write its `tag_<key>` attribute.** The event is appended; it
simply does not appear in that one index. DynamoDB indexes are sparse by design, so this is the
mechanism working as intended rather than a workaround.

Three properties make this cheap:

1. **The composite key is unaffected.** `compositeTagKey` joins `key:value` pairs with `#`, so an
   empty member still yields a valid non-empty string. The `tag_composite` GSI, the partition key
   derivation and the OCC fence all keep working unchanged.
2. **The per-tag GSIs have no reader today.** The adapter's own comment records this: they are
   `KEYS_ONLY` because "they have no reader today (single-tag reads use the base-table partition)",
   with a cross-partition reader planned. So the immediate behavioural delta is nil.
3. **It is semantically right.** An empty value is not an identity anyone can query for — DynamoDB
   cannot express `tag_x = ""` as a key condition at all. Absence from the index is the honest
   representation.

### Alternatives considered

| Option | Why not |
|---|---|
| Reject empty tag values at the command boundary | Turns a silent failure into a loud one, but still refuses writes the model considers valid, and diverges from the backends that accept them. |
| Substitute a sentinel (`"-"`, `"(none)"`) in the adapter | Puts a fabricated value in the index that every reader must then know to exclude — the storage layer inventing domain vocabulary. |
| Guard per spec, at each call site | The status quo. It has already been done once for a single field, with a comment naming this exact failure, and the bug simply reappeared on the next field that could be empty. A per-field guard does not generalise. |

## Items

### D1 — skip empty tag attributes in the item builder

Guard the write in `DcbEventLogStorage_DynamoDb_Runtime.res`: only set `tag_<key>` when
`tag.value != ""`. Keep the tag in the event's own `tags` payload — the event must still *record*
the empty value, so a reader that resolves the item sees the tag exactly as written.

Unit-test the builder directly: an event with one empty and one non-empty tag produces an item
carrying only the non-empty `tag_` attribute, while `tag_composite` and the payload keep both.

### D2 — conformance case across backends

Add to the conformance kit (see `docs/plans/conformance-test-kit.md`): *an event with an empty tag
value appends successfully, is readable through its partition, is present in a composite-tag read,
and is absent from that tag's single-tag index.* This is the case that would have caught the
divergence, and it pins the contract for any future backend.

### D3 — document the contract

State it where `@compositePartitionTag` is documented (`packages/doc/docs-app/reventless-ppx.md`):
an empty tag value is permitted, participates in the composite key, and is not individually
indexed. Without this, the next person to see a missing row in a per-tag query has no way to know
it is by design.

### D4 — optional: surface empty partition members at append

A composite partition key whose members are *all* empty degenerates to a constant, putting every
event of that slice in one partition. That is a modelling error rather than a storage one, so it
belongs at most as a debug-level log, not a failure — but it is worth knowing about while the
composite-key story is still young. Defer unless it shows up.

## Migration

None. Appends that hit this failed atomically — the item was rejected, so no partial event exists
and nothing needs rewriting or backfilling. Events that previously failed will append the next time
their producer runs. Existing events are untouched, and the GSIs need no re-provisioning: making an
index sparse is a write-path change only.

## Risks

- **A cross-partition reader would not see empty-tagged events under that tag.** Correct, and
  unavoidable — the key cannot hold an empty string. Worth stating in D3 so the planned
  cross-partition read is designed knowing it.
- **A future reader assuming the per-tag GSI holds every event** would find a sparse one. There is
  no such reader today (the KEYS_ONLY comment above), so the assumption is cheap to prevent now and
  expensive to unwind later.

## Done when

- An event carrying an empty tag value appends on DynamoDB, and the item's `tag_` attribute set
  omits exactly that key.
- The conformance case passes on the in-memory, SQLite and DynamoDB backends, so the three agree.
- The `@compositePartitionTag` documentation states the contract.

## What was implemented

**D1** — `toItem` skips `tag_<key>` when the value is empty
(`DcbEventLogStorage_DynamoDb_Runtime.res`). Unit-tested in
`reventless/aws/tests/DcbEventLogStorage_DynamoDb_RuntimeTest.res`: the non-empty tag keeps its
attribute, the empty one has none, `tag_composite` carries both, and the `tags` payload records
the empty value verbatim.

**D1b (added during implementation, not in the original plan)** — the *read* side needed the same
guard. `queryBySingleTagCrossPartitionStream` builds a `KeyConditionExpression` from the tag value,
and DynamoDB rejects an empty key-condition value just as it rejects an empty key attribute — so
the cross-partition read of an empty value would have *thrown* rather than returning nothing, which
is worse than the Risks section anticipated. It now short-circuits to `Stream.empty`. Both read
entry points (`executeQueryItem`, `executeQueryItemStream`) route through the guarded function.

**D2** — the conformance kit does not exist yet (`docs/plans/conformance-test-kit.md` is still a
draft; there is no `reventless/conformance` package), so the case was written three times in the
homes the kit will eventually absorb, and the kit plan's suite-2 inventory now names it so it gets
ported rather than re-derived:

| Backend | File |
|---|---|
| in-memory | `reventless/local/tests/adapter/DcbEventLogStorageTest.res` |
| SQLite | `reventless/local/tests/adapter/DcbEventLogStorageSqliteTest.res` |
| DynamoDB | `reventless/aws/tests/integration/DcbEventLogStorage_DynamoDb_IntegrationTest.res` |

The backend-neutral assertions are: appends, records the empty value verbatim, matches through its
partition read, matches through a composite read. The fourth clause of the planned case — *absent
from that tag's single-tag index* — is DynamoDB-only in a way worth being precise about: a
single-tag read on the local backends, and a non-`@crossPartition` single-tag read on DynamoDB, go
against the base-table partition and **do** return the event. Only a `@crossPartition` read goes
through the per-tag GSI, so that is what the DynamoDB arm asserts (empty result, no exception).

**D3** — `packages/doc/docs-app/reventless-ppx.md`, `@compositePartitionTag` section: a constraints-
table row plus an "Empty tag values" block stating that the value is recorded, participates in the
composite key, is not individually indexed, and is therefore not findable by a cross-partition read.

**D4** — deferred, as the plan directed.

### Verification

`reventless-aws` (22 suites, 288 tests) and the two `reventless-local` DCB storage suites are green.
The DynamoDB arm of D2 **compiles but has not been executed**: it lives in the integration lane,
which needs a DynamoDB Local container, and Docker was unavailable on the machine this ran on. That
lane is `continue-on-error` in CI, so it does not gate — the item-level guard is what the gating
unit suite proves.
