# Plan: close the two owner-scoping gaps that only exist on AppSync

**Date:** 2026-08-16<br/>
**Status:** found by running the owner-scoping acceptance against a deployed
stack for the first time. Both defects were **live**, both are **AppSync-only**,
and the in-process platform passes the same assertions — so every test and every
browser run to date had been green while a deployed shop trusted the client.
✅ **Both are now fixed in source, with tests, and neither is released or
deployed** — the deployed stack still carries them until a release and a deploy,
and the acceptance below has to be re-run against that deploy before either is
called closed.<br/>
**Relates to:** `owner-scoped-identity-and-reads.md` (the feature these two sites
were missed by), `denied-query-returns-empty.md` (why the read gap is hard to
notice from outside).

The two are independent and can land in either order. The write gap is the
serious one: it is the difference between a row that records who placed an order
and a row that records whatever the client typed.

---

## Defect 1 — the DCB command path stamps nothing, because its schema was
## replaced with a permissive one

`stampOwnerFields` finds the fields to stamp by asking the command schema:

```rescript
switch Reventless.Owner.variantFieldNames(commandSchema, ~variant=command) {
| [] => ()          // ← nothing marked an owner: nothing to do
| ownerFields => …
}
```

Two of the three DCB call sites hand it `S.json`:

| Site | `~commandSchema` | Stamps? |
| --- | --- | --- |
| `Dcb_Builder.res:547`, `:574` (in-process, per slice) | `S.Spec.commandSchema` | ✅ |
| `Dcb_Builder.res:772` (the AppSync-backed topic) | `S.json` | ❌ |
| `DcbCommandTopicEntryPoint.mjs:209` (the Lambda shell) | `jsonSchema` | ❌ |
| `AggregateEntryPoint.mjs:181` (aggregates, for contrast) | `patchedSpec.commandSchema` | ✅ |

`Owner.variantFieldNames` falls to its `| _ => []` branch for `S.json` — neither
a `Union` nor a tagged `Object` — so the write publishes the caller's own
`customerId` unchanged. There is no error and no warning; the row is simply
wrong, and it stays wrong.

**The substitution was correct when it was written, and the reason it stopped
being correct is the point.** Both sites carry the same comment — *"commandSchema
validation is skipped (permissive JSON.t schema) because AppSync already
validates input against the SDL"* — and as an argument about **validation** it
still holds. Owner stamping then gave the schema a second job: it is now also
where the `@owner` marker is read from. A schema swapped out for one job silently
lost the other. This is the same shape as the visibility filter that doubled as a
ref-resolution gate (`internal-views-referenceable.md`); the lesson that
generalises is that a permissive stand-in is only safe while the thing it stands
in for is consulted for exactly one question.

**Fix.** Both AppSync DCB sites must pass the slice's real
`S.Spec.commandSchema`, as the two in-process sites and the aggregate shell
already do. The Lambda shell already loads `specModule` per slice when it builds
`inboundReceiversByField`, so the schema is in hand at the point the generator is
built; what it lacks is a per-field generator, since today one permissive
generator backs every field. Route the binding the way `Dcb_Builder.res:547`
does — one generator per slice, bound to that slice's own mutation fields.

⚠️ **Keep the permissive *decode*.** The fix is about which schema is consulted
for owner fields, not about reinstating validation in the shell: per-slice
decoding still happens inside `buildSliceHandler`, and moving it forward would
change what a malformed payload does. Pass the real schema; do not add a decode.

**The test that would have caught it, and belongs in the fix**, is a conformance
table like `Auth_ActiveRole.conformanceCases` — the same (identity, command,
sent value, expected stored owner) rows run against every command path there is.
A per-path unit test would not have caught this: each path was individually
correct about the schema it was given.

---

## Defect 2 — the single-row read carries no owner predicate

`Ordering_Order(id:)` returns another customer's row to a scoped caller. In
`QueryDbResolvers_AppSync.res` the list resolver is built with the predicate:

```rescript
Resolver.Functions.listAllItemsConnection(…, ~ownerField?, ~elevatedGroups=…)
```

while the by-id resolver a few lines above (`:172-178`) is built from
`Resolver.Functions.getItemById` / `queryByIdSort`, which take neither argument.
`ownerField` is not even computed until `:243`, after the by-id resolver is
constructed.

The in-process platform scopes both, so this is transport drift of exactly the
kind the owner plan warned about — and it is invisible from the list, which
behaves perfectly. A caller who can *see* only their own rows can still *read*
any row whose id they can guess or has ever been shown to them.

**Fix.** Compute `ownerField` before the by-id resolvers are built and thread it
into both `getItemById` and `queryByIdSort`, refusing (not emptying) a row whose
owner is not the caller when the caller is not exempt. A single-row read is the
one place a refusal can be honest without the ambiguity
`denied-query-returns-empty.md` describes: there is no "you own nothing" reading
of a request for one named row.

**`queryItemsWithSortConditions` (`:190`) is the third site** and needs the same
treatment — it is a list in everything but name.

---

---

## What was built

**D3.** Both AppSync DCB sites now build **one generator per command**, keyed by
the constructor TAG the resolver injects, each carrying that slice's own
`commandSchema` — `Dcb_Builder.res` for the in-process route and
`DcbCommandTopicEntryPoint.mjs` for the Lambda. They differ from each other in
nothing but the schema; the publish path, the component kind and
`stripIdFromParams` are all as they were, and no decode was added.

Two things fell out of the shape rather than being designed in. Keying by TAG is
sound because a multi-command slice's constructors already have to be unique
within a plugin — their mutation field names are `${plugin}_${command}` and would
collide first — which leaves single-command slices as the only way two schemas
could claim one name, so **both sites refuse the ambiguity loudly** rather than
letting the last writer win. And a command no slice claims keeps the permissive
generator, so anything arriving by another route behaves exactly as before; it
cannot stamp, so it **warns**, which is the difference between a gap and a
silence.

**D4.** `ownerField` is now resolved at the top of `resourcesMaker`, above the
by-id resolvers instead of well below them, and threaded into all three reads.
`getItemById` and `queryByIdSort` guard in the **response** — a `GetItem` has no
FilterExpression, and a `Query` that filtered server-side while its sibling
guarded downstream would be one rule with two implementations, the cheaper of
which nobody would remember to change. `queryItemsWithSortConditions` scopes in
the **request**, like `listAllItemsConnection`, because it is a list: narrowing
after the page is cut would report `hasNextPage` from a count the caller was
never allowed to see.

A foreign row reads as **null, not an error**, which is worth stating because the
first draft of this plan argued the opposite. Two things overrule it: the
in-process platform already answers `null`, and a rule enforced differently per
transport is the failure this whole item is about — and an error would confirm to
a caller who may not read the row that the row exists.

**Tests.** 9 new cases on the by-id readers (owner, foreign, elevated, the
IAM-shaped identity with no `sub`, an absent identity, a missing row, an
unscoped view, the sort variant, and the request-side one), and 3 on the write
path. The last of those is the check the defect actually needed: not "does this
call site stamp" — every call site was individually correct about the schema it
was handed — but **"can the schema a generator is built with answer for the
commands it will be given"**. The permissive case is pinned as the defect it is,
beside the same payload and caller going through the real schema.

## Acceptance

Run against a deployed stack, not only in-process — that is the whole finding.

1. A scoped caller places a command whose owner field names **another** caller.
   The stored row comes back owned by the caller. Run it on a DCB slice and on
   an aggregate, because today those two answer differently.
2. The same caller reads that other owner's row **by id** and is refused.
3. An exempt caller does both and is unaffected: the value it sent is kept, and
   it reads any row.
4. A caller the deployment cannot identify is refused the write outright rather
   than publishing an unstamped command.
5. The conformance table from defect 1 runs green on every command path, and
   fails if any path is handed a schema that answers `[]` for a command whose
   spec marks an owner.
