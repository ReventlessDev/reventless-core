# Plan: generated surfaces state the access they require

**Status.** Core half landed — 2026-08-11. `commandDef` and `queryableDef` carry
derived `requiredAccess`, encoded into both admin queries and inherited by the
baked manifest. What remains is the consumer: a shell that reads the keys, and
the policy for what it does with a denied surface (§8).

**Goal.** A generated page or panel carries the access its own authorization rule
already implies, so a shell can stop advertising surfaces the server will refuse.

**Non-goal.** Deciding what a shell *does* with that knowledge. Hiding, locking
or upselling a denied surface is a client policy, and a deployment serving
license tiers wants a different one than a deployment serving job roles.

---

## §1 — What is broken

`Plugin_Builder` stamps `requiredAccess: None` on every generated page and panel
it produces (`reventless/core/src/plugin/component/Plugin_Builder.res:1056`,
`:1063`, `:1069`). The value is not computed and never has been.

The shell's gating machinery is fully built and wired — it resolves a caller's
keys as `identity.groups ++ config.accessTiers` and gates each surface on
`requiredAccess`. It simply has nothing to gate on, because every surface it
receives declares that it requires nothing.

The result is a menu that lies. A component annotated
`@authorize(AllowGroups(["Admin"]))` still gets a nav entry for a caller with no
`Admin` group; the caller clicks it and the command is refused. On the read side
it is worse than a refusal: a denied query returns an empty connection rather
than an error (`docs/plans/Backlog/denied-query-returns-empty.md`), so the page
renders as a confident, empty, permanently-broken table.

## §2 — The rule already exists, and is already evaluated

The obvious shape — a new annotation, `@@reventless.access("Admin")`, mirroring
`@@reventless.visibility` — would make an author state the same fact twice: once
for the server, once for the menu. Two statements of one fact drift, and this
pair drifts in the dangerous direction, because the copy that governs the menu is
the copy nobody tests.

Both rules are already in hand at the moment the manifest is built:

- **Per command.** `Plugin_Builder` evaluates the PPX-generated
  `commandAuthorization` against a synthetic value per constructor and collects
  the results into `fieldPermissions` (`Plugin_Builder.res:222-232`, mirrored in
  `Plugin_Helpers` and `Dcb_Builder`). The rule per mutation field is a value in
  the builder, not something to go and fetch.
- **Per view.** A component's module-level rule is read as `R.Spec.authorization`
  a few lines away (`Plugin_Builder.res:258`).

So the work is routing a value that exists, not adding an authoring surface.
`requiredAccess` becomes **derived**, and the server rule stays the single place
an author states who may do what.

## §3 — The mapping

`Authorization.permission` is a closed variant
(`reventless/spec/src/types/Authorization.res`), so the mapping is total:

| Rule | Access keys | Why |
| --- | --- | --- |
| `AllowGroups(gs)` | `gs`, satisfied by **any** | Mirrors `isAllowed`, which is `some`, not `every` |
| `AllowAuthenticated` | none | Every caller who can see a shell at all already satisfies it |
| `AllowAnonymous` | none | Same, weaker |
| `DenyAll` | **omit the surface** | See below |

`DenyAll` deliberately does not become "requires a key nobody holds". A shell
policy that renders denied surfaces as locked-with-upsell would advertise a
surface no upgrade can ever unlock — a lie told in the vocabulary of a sales
offer. A component nobody may call has no reason to appear in a manifest.

**Keys are strings and the namespace is shared** with `config.accessTiers`, by
existing design: the client already unions groups and tiers into one set. That is
what lets a role and a licence tier gate the same surface without the client
learning the difference. It also means a group named after a tier collides, which
is a deployment's problem to avoid and worth one line in the guide.

## §4 — What still needs authoring

A licence tier has no server-side rule — it is granted by deployment config, not
by a token, and no `@authorize` annotation expresses it. So an explicit
annotation stays necessary for exactly that case, and its documentation should
say so plainly: **use it for keys the server does not enforce; never to restate a
group `@authorize` already states.** Where both exist, the derived keys and the
declared keys union.

## §5 — Emission

`requiredAccess` travels the same road as `chapter` and `visibility`: computed in
the builder, carried on the manifest entry, encoded into both manifests. Two
things to get right, both of which have bitten this seam before:

- **Both transports in one version.** The in-memory encoder and the AWS Lambda
  handler each build entries, and the persisted plugin structure on AWS is
  re-encoded at query time. A change landing in one produces a shell that gates
  correctly in dev and not at all when deployed.
- **The baked manifest inherits it for free** if the field rides on the entry,
  since the bake filters structures and reuses the served encoder. Worth an
  explicit test rather than an assumption, because the baked path is the one
  whose consumer cannot fall back to anything.

## §6 — The line this plan does not cross

Client gating is UX. It stops a shell from offering what the server will refuse;
it protects nothing. Every key in the manifest is a hint whose authority lives in
the resolver, and a caller who edits the file gains exactly nothing. That is why
the derivation direction matters: the manifest follows the rule, never the
reverse.

## §7 — Tests

- Each `permission` arm maps to the keys in §3's table; `DenyAll` yields no
  surface at all.
- A command whose rule is `AllowGroups(["Admin"])` produces a page entry whose
  `requiredAccess` names `Admin`; a sibling command with no annotation in the same
  component produces one with none — the per-constructor evaluation is what makes
  this possible, and it is the case a component-level shortcut would get wrong.
- A view's module-level rule reaches its list page and its panel.
- The baked manifest carries the same keys as the served one for the same
  component.
- Both transports emit identical keys for one fixture structure.


---

## §8 — What landed, and what is left

Landed: the derivation (`Plugin_Structure.accessKeysFor`, evaluated per command
constructor and per view), the two new fields, the SDL and encoders shared by
both admin queries, and five tests including the one that matters most — a
sibling command in the same slice publishes nothing while its gated neighbour
publishes its groups.

Verified live against the hybrid example: nine catalog commands, `ShipOrder`, the
demand view and the customer list publish `["Admin"]`; the shop's own commands
publish null. The baked storefront manifest is all-null, which is the right
answer for a file that only contains surfaces open to any signed-in caller.

**One shape adjustment against §3.** The plan said `DenyAll` should make the
enumerating side *omit* the surface. The derivation publishes no keys for it
instead, because omission is a decision for whoever builds pages — a structure is
also read by tooling that wants the whole picture, and dropping a component from
the structure would hide it from the event graph too. The consumer still has what
it needs: nothing in this repo currently emits `DenyAll` on a user-facing
component, and a shell that wants to drop such a surface should read the rule,
not a key.

**Not done — the consumer.** A shell still passes no access keys into its page
generation, so nothing gates yet. That work belongs with whoever owns the shell,
along with the policy question this plan deliberately left open: a denied surface
can be locked (right for a licence upsell) or absent (right for a role split),
and the two are different products, not different opinions.

**A note the golden list already records.** Adding these fields moved
`tests/plugin/pluginDefinitionRequiredScalars.txt`. Same shape as `allowedStates`
— a nullable array whose element is a scalar — and accepted on the same terms: an
older persisted definition carries no array at all, so there is no element for the
healer to invent.
