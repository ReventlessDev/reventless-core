# Plan: one curated manifest per audience, not per deployment

**Status.** The local half **built 2026-08-13** (core `3be6f63e5`), with the
shell reading it (`reventless-ui: 17e9c04`) and the hybrid example declaring a
journey per role. The deploy still writes one file — §7 step 3 is open.

Two things the build settled. The **default journey comes first and stays**, which
is what a caller matching no declared group gets — including, locally, the
no-bearer identity every dev session starts from. And **every file is curated
before any is written**: a declaration naming a missing component already fails
the boot, and failing it halfway would leave one audience's file beside a stale
copy of another's.

**Sibling plans:**
- `docs/plans/ui-manifest-baked-emission.md` — the single-manifest bake this
  generalises. Read it first; everything here is its declaration growing a
  dimension.
- `docs/plans/active-role-narrows-the-token.md` — decides what a role *may do*.
  Independent of this plan and buildable in either order, but see §5: without it,
  this one curates a menu the server does not agree with.

**Goal.** A deployment serving several audiences can curate a surface for each,
and a caller discovers the one that matches the role they are acting as.

---

## §1 — What the single manifest cannot express

`bakedManifest` names one include-list, which the platform curates and writes to
one file, and every non-elevated caller reads that file. That is exactly right
for a deployment with one audience, and it was built for one.

It has no way to say "a shopper sees these components and a fulfilment agent sees
those". Today the only answers are to publish the union — which puts every
audience's surfaces in everyone's menu and leans on server-side authorization to
make the extra ones merely useless rather than harmful — or to run a separate
deployment per audience, which is the honest answer when the audiences share
nothing and pure overhead when they share a domain.

## §2 — Shape: the existing declaration grows a dimension

```rescript
type journey = {
  group: string,
  label?: string,           // defaults to the group
  components: array<selection>,
  key?: string,             // defaults to a per-group file name
}
```

`bakedManifest` grows `journeys` beside today's `components`, and **the existing
field becomes the default journey** — what a caller matching no declared group
gets.

That is not only backward compatibility, and the reason is worth keeping: the
in-memory platform's no-bearer identity carries a group no deployment declares,
so a design with no default would leave local dev without a login matching
nothing and rendering an empty shell. The failure would appear only in the
configuration everyone develops against.

Downstream is mechanical. `Platform_BakedManifest.curate` already takes
`~selections` and returns one manifest, so N journeys is N calls and N keys; the
local writer writes N files instead of one; the deploy's write grant widens from
one key to the declared set; `config.json` carries a group→url map beside the
single `manifestUrl`.

## §3 — Curation is still not authorization

Leaving a component out of a journey keeps it out of that role's menu and makes
it no less callable. Nothing here decides what a caller may do; the server does
that, per query and per mutation, and decides it the same whether or not a
component is named in any journey.

This sentence is already in the single-manifest plan and it matters more here,
because a per-role manifest *looks* like a permission model in a way a
per-deployment one does not. Journeys decide what is **offered**. The token
decides what is **permitted**. A reader who conflates them will eventually ship a
deployment whose only defence against a role is that its menu does not mention
it.

## §4 — The bug this closes, which is not the feature it was proposed for

Discovery currently routes a caller to the admin API when they hold a group the
deployment names as elevated. But the admin API is gated on the group `Admin`
specifically — `requireGroup(~group="Admin")` locally,
`injectAwsAuthAll(~group="Admin")` on AWS, both hard-coded.

Those two sets are identical only while `Admin` is the only elevated group. Add a
second — a role whose job is reading rows other people own, which is precisely
the case the exemption exists for — and that caller is routed to a door it cannot
open, landing on `Unauthorized: requires group "Admin"`.

Journeys close it structurally: an elevated non-admin discovers from **its own
file** and never asks the admin API at all. The alternative repair is to teach
discovery which group actually gates the admin API, which is the shell's to make
and is written up in the ui sibling plan; it stays worth doing for a deployment
that wants an elevated role *without* a journey of its own.

**The rule to write into the reference docs either way:** the elevated-groups
declaration answers exactly one question — who reads across owners — and must not
be read as naming operators.

## §5 — Why this is worth building even though it is not the security half

On its own, journeys give each role a menu. The server still accepts whatever the
caller's token authorizes, so a role that switched journeys but not groups sees a
narrower menu and retains every permission it had.

That is not a reason to defer it; it is a reason not to ship it *described* as a
role system. Paired with the token narrowing it is a complete feature. Alone it
is a curation feature, which is a real thing a deployment wants, and the
paragraph in §3 is what keeps the two apart in the reader's head.

## §6 — Decisions

**6.1 A caller matching several journeys.** Possible once a user holds several
groups. Resolving to the union would rebuild the problem this plan exists to
solve. Proposal: the active role decides, and where no role is active, the
default journey — never a merge, because a merged menu belongs to no declared
audience and cannot be reasoned about from the declaration.

**6.2 Journeys are distinct audiences, not slices of one.** If a deployment
declares journeys sharing most of their components, the split it wants is in
navigation, not in curation. Worth saying in the docs beside the declaration: the
cost of a journey is a manifest to keep correct, and two that differ by one entry
are two chances to get it wrong.

**6.3 Elevation stays orthogonal.** A journey does not imply an exemption from
owner scoping and an exemption does not imply a journey. They answer different
questions and the example that motivated this plan needs one role with each.

## §6b — What a journey could not curate, and now can

**Built 2026-08-14.** A selection named views and commands, which is every surface
a plugin *declares*. It is not every surface a shell *builds*: the shell also
generates, per plugin, a dashboard, a lifecycle diagram, a canvas and a scheduler
— pages drawn across a plugin's views rather than from any one of them.

Those arrived regardless of the include-list, which made the whole declaration
half a promise. The hybrid shop showed it exactly: the storefront names one
Ordering view, and a customer still got a state machine of the order pipeline and
a calendar of delivery windows, in a menu group labelled `Ordering` — because a
page belonging to no view has no view's `nav` hint to name it, so it falls back to
the plugin's name. A shop that curated its views down to a storefront and still
offered "Ordering" beside "Shop" curated nothing.

So a selection grows a third list, `derived`, with the same semantics as the other
two: unset ⇒ every kind, set ⇒ exactly those. The storefront takes none;
`Fulfilment` takes `["lifecycles", "canvas"]`, which is the board it works.

**Kinds, not page names.** The vocabulary is closed — `dashboard`, `lifecycles`,
`canvas`, `scheduler` — and validated against itself rather than against the
plugin. Two reasons, and both are about who knows what. A canvas is *named* in the
browser, from that deployment's hints and the view modes its shell registered, so
a publisher validating names would fail deploys over a spelling only the shell can
check. And whether a kind generates anything is a fact about the plugin's schemas,
not about the declaration: a shop naming `lifecycles` before its views carry a
status is early, not wrong, and failing it would punish the deployment for the
order it did things in.

**Absent is not empty, all the way out.** The key is omitted from the encoded
entry when the selection says nothing, so the admin path — which curates nothing —
emits no key, and a manifest baked before the field behaves as it always did. A
curated entry wanting none says `[]`. Collapsing the two would take the dashboard
away from every operator console that never asked for curation.

## §7 — Steps

1. The `journeys` declaration + N-way curation, with the existing field resolving
   as the default. Tests: a deployment declaring only `components` produces a
   byte-identical file.
2. The local writer: N files, and the group→url map into the served config.
3. The deploy's write grant and upload, same declaration.
4. Reference docs: §3's distinction and §4's rule.

## §8 — Acceptance

- A deployment declaring no journeys writes exactly the file it writes today,
  under the same name, and its config carries the same single key.
- A deployment declaring journeys writes one file per journey plus the default,
  and each contains only that journey's components.
- A caller whose active role matches a journey discovers from that journey's file
  and makes no admin-API request — including a caller the deployment treats as
  elevated, which is §4's case.
- A caller matching no journey gets the default.
- A selection that names no `derived` list produces the file it produced before
  the list existed, and a caller discovering from the admin API gets every kind.
- A journey naming `derived: []` renders no page built across its plugin's views,
  and no route that would reach one.
