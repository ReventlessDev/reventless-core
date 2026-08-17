# Plan: an elevated caller can widen every door to the archive except the index one

**Status.** Backlog — filed 2026-08-17, left out of
[dynamodb-narrows-every-door.md](../done/dynamodb-narrows-every-door.md) on
purpose. That plan closed the narrowing half on DynamoDB; this is the widening
half, and it is not DynamoDB's alone.
**Relates to:** [done/retired-state-flag-annotation.md](../done/retired-state-flag-annotation.md)
(the rule), [retired-row-resolvable-by-reference.md](../retired-row-resolvable-by-reference.md)
(the same asymmetry argued for the reference door).

## What happens

`@retired` withdraws a row from ordinary reads, and an elevated caller reaches
the archive by passing `includeRetired: true`. The documented set of doors that
accept it is the list, the single-entity and the by-ids one — and the by-index
door is missing from that set, on **every backend**:

| backend | narrows retirement on by-index | can be widened |
|---|---|---|
| local (in-memory / SQLite) | ✅ `QueryDbResolvers_GraphQL.res:811-812` | ❌ resolver reads `includeRetired`, SDL does not declare it |
| Postgres | ✅ `PgQueryResolver_Lambda.res:375-378` | ❌ same — read at `:192-196`, undeclared |
| DynamoDB / AppSync | ✅ `AppSync_Resolver_Functions.res:620` | ❌ argument skipped defensively at `:605` |

So all three resolvers were written to honour the argument and none of them can
receive it, because no SDL emitter declares it on that field. An operator who can
open an archived row by id, and see it in the archive listing, cannot reach it
through the index that exists to find it.

## Why it is worth changing

**The narrowing is already unconditional, which is the part that makes it a
defect rather than a gap.** A door nobody could widen would be defensible if it
also refused nobody; this one withholds rows from the caller it exists to serve
and offers no way to ask. The plan that closed the DynamoDB narrowing named this
as the asymmetry it was creating.

**Three resolvers already implement the widening.** The cost here is not the
predicate — it is written, three times over — it is the schema field that lets a
caller reach it. Leaving it means three pieces of live code that no input can
ever exercise, which is how a behaviour rots without a test noticing.

**The defensive skip is load-bearing until this lands.** The AppSync index
templates turn every unrecognised argument into `contains(#key, :key)`, so an
`includeRetired` arriving at a template that does not know it becomes a filter on
an attribute no row carries — the door answering nothing at all. The skip at
`AppSync_Resolver_Functions.res:605` exists so that adding the SDL argument
cannot land on that trap, and it has to be removed *by* this change, not before.

## The obstacle: two emitters that disagree

This is why it is not a one-line change. The by-index field is emitted twice, by
paths that never meet, and they agree on nothing:

| | core fragment generator | local adapter |
|---|---|---|
| where | `GraphQL_FragmentGenerator.res:724-726` | `QueryDbResolvers_GraphQL.res:793-794` |
| name | strips a leading `by`, then capitalises (`byOwner` → `XByOwner`) | capitalises only (`byOwner` → `XByByowner`) |
| args | `id: ID!` + Relay paging | one required arg named for the index (`owner: String!`) |
| returns | `<Type>Connection!` | `[String]` |
| reaches | DCB StateViewSlices and the admin plugins model only | aggregate-style read models |

`entry.indexQueries` is populated only by `Dcb_Builder.res:1096-1109` and
`PluginBaseFragment.res:39-63`; `Plugin_Builder.res:246-262` builds an ordinary
read model's query entry without it. **So an aggregate read model's `@index` gets
a resolver on AWS and no SDL field to call it with** — a second defect this work
would surface, and arguably the one to fix first, since a field that does not
exist cannot be given an argument.

Adding `includeRetired` in lockstep means reconciling the two emitters, or
deciding deliberately that they stay divergent and each grows the argument in its
own shape. Reconciling is the larger change and the right one; it is also a
breaking rename for anyone querying `xByByowner` today.

## Care needed

- **One SDL serves every backend** (`QueryDbResolvers_AppSync.res:507-509`), so a
  field added on one path must have a resolver on all of them or it errors where
  it is unimplemented. This is the reasoning that made the reference door
  unconditional; it applies here unchanged.
- **Remove the AppSync skip in the same change**, never earlier.
- **The argument widens, it never narrows.** `OwnerScope.decideRetired` stays the
  one place that decides who may ask; a non-exempt caller passing it is ignored
  rather than refused, as on the other three doors.
- `@owner` is deliberately *not* applied on a group-restricted index — see the
  reasoning recorded in the parent plan — and nothing here should change that.
