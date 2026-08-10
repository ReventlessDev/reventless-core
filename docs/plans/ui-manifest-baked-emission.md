# Plan: Baked component manifest as a static asset

**Status.** Proposed — 2026-08-10.

**Sibling plan:** `reventless-ui: docs/plans/shell-static-manifest-and-end-user-mode.md`
— the shell-side `manifestUrl` discovery path that consumes what this plan
writes.

**Prerequisite plan:** `docs/plans/internal-views-referenceable.md` — adds
`internalQueryables` to the manifest entry. **It must land first.** §5 requires
the baked file to carry that field, and a shell reading a baked manifest has no
admin API to fall back on — so a reference target missing from the file is
missing permanently, in the one deployment shape with no recovery path. Baking
before the field exists means authoring the emission against a field that is not
there yet and revising it afterwards.

**Goal.** A deployment can serve the component manifest as a **static JSON file**
beside `config.json`, curated to a declared subset of components — so a shell can
discover its surfaces without calling the platform's admin API at all.

**Non-goal.** A live manifest query for non-admin callers. A durable
`Domain_UIManifest` field is a different design with different cost; this plan
deliberately takes the static route and says so in §6.

---

## §1 — Why a static file

`Platform_ComponentDefinitions` and `Platform_UIFragments` are admin-gated: both
reject a caller outside the elevated group with
`Unauthorized: requires group "Admin"`, identically to an unauthenticated
caller. That is correct — the manifest describes the whole platform, including
components an operator curates and a non-operator has no business enumerating.

But it means the *only* discovery path a shell has is one that most callers
cannot use. A shell serving a non-elevated audience currently renders nothing at
all, because discovery fails before authorization on any individual view is ever
consulted.

A baked file separates the two concerns cleanly:

- **What exists for this deployment's audience** — deployment data, curated at
  deploy time, served statically. No API, no gate, no round-trip.
- **What this caller may do** — server-side authorization, unchanged, enforced
  per query and per mutation.

The second is the security boundary and is untouched by this plan. The first is
curation, and curating it at deploy time is strictly more honest than fetching
the full platform manifest and hiding parts of it client-side.

## §2 — Precedent: mirror `ui-hints.json` exactly

The framework already ships one static, optional, deploy-authored JSON asset
beside `config.json`, and its conventions are settled:

| Concern | `ui-hints.json` today |
| --- | --- |
| Config key | `uiHintsUrl`, default `/ui-hints.json` (`reventless-ui: Config.res:120,217`) |
| Local dev | host-shell serves `public/ui-hints.json` directly (`reventless/local/src/Platform.res:2036-2038`) |
| AWS | `hostUiBundle.uiHintsFile` → `BucketObject` beside `config.json` (`reventless/aws/src/Platform.res:2178-2193`) |
| Absent | 404 ⇒ warn once, boot unchanged, byte-identical to a deployment without it |
| Malformed | fails the **deploy**, not the boot (`Util_StaticBundle.readJsonFileVerbatim`) |

This plan adds a second asset on the same terms. Every design question below has
the same answer as the hints file, and deviating from it needs a reason.

**One deliberate difference.** `uiHintsFile` is a path to a file the *deployment
author* wrote. The manifest is **generated** — its content is derived from the
registered plugins' structures, which only the framework knows. So the
deployment declares *what to include*, not *what to write*.

## §3 — The curation declaration

`hostUiBundle` gains an optional field on the shared `Platform.T` signature
(`reventless/infra/src/types/Platform.res:353` is where `uiHintsFile` sits):

```
type bakedManifestSelection = {
  plugin: string,
  // None ⇒ every public component of that plugin. Some([…]) ⇒ exactly these,
  // by component name.
  views?: array<string>,
  commands?: array<string>,
}

type bakedManifest = {
  include: array<bakedManifestSelection>,
  // Defaults to "component-manifest.json", beside config.json.
  key?: string,
}
```

Unset ⇒ nothing written ⇒ `GET /component-manifest.json` 404s ⇒ any shell
configured for it boots exactly as it does today. That is the same
absent-is-inert contract as the hints file, and it is what keeps this change
non-breaking for every existing deployment.

An include-list rather than an exclude-list: a component added later must be
opted **in**, so growing the domain cannot silently widen a curated shell's
surface.

**Naming a component that does not exist should fail the deploy.** A silent
no-op here produces a shell that is missing a page for a reason no log explains
— the same class of failure as a malformed hints file, and it gets the same
treatment.

## §4 — Emission

The manifest content is the array `Platform_ComponentDefinitions` returns,
filtered by the include-list — same encoder, so the two can never drift in
shape:

```
Platform_ComponentDefinitionsApi.encodePluginStructureEntry(~pluginId, structure)
```

- **In-memory** (`reventless/local/src/Platform.res`): the platform holds every
  registered plugin's structure in process. Write the file into the host-shell
  package's `public/` dir at `deployPlatform`, next to where `config.json` and
  `ui-hints.json` are already served from.
- **AWS** (`reventless/aws/src/Platform.res`): the per-plugin structures are not
  in the deploy's hands — they are persisted into the Plugin read model as each
  plugin deploys, which is why the admin API reads them at query time. Two
  options, and the choice needs making before implementation:
  1. **Emit at platform deploy from the Pulumi-visible plugin set** — works only
     if the platform deploy can see every plugin's structure, which it cannot in
     a per-plugin-stack topology.
  2. **Emit as a post-deploy step** that reads `Platform_ComponentDefinitions`
     with operator credentials and writes the curated result as a
     `BucketObject`. Decoupled from plugin deploy order, and the natural fit for
     a pipeline that already deploys plugins independently.

  Option 2 is the recommendation. It makes the bake an explicit pipeline step
  with an obvious failure mode, rather than a deploy-time invariant that a
  per-plugin topology cannot hold.

## §5 — Carry `internalQueryables`

The baked file must include the `internalQueryables` field added by
`docs/plans/internal-views-referenceable.md`, restricted to entries actually
referenced by an included command. Omitting it reintroduces exactly the defect
that plan fixes, in the one deployment shape that has no fallback: a shell
reading a baked manifest never queries the admin API, so a missing reference
target cannot be recovered from anywhere.

An Internal view in the baked file is not a disclosure — §1's split holds, the
domain API already serves that view to the same caller, and the file names it
only because a command in the same file references it.

## §6 — Deferred, deliberately

**A live manifest query for non-admin callers.** A `Domain_UIManifest` field
served off the domain API would let surfaces change without a redeploy. It is
not obviously wanted: the manifest describes what the deployment *is*, and a
deployment changing shape without a deploy is a property to argue for, not to
assume. Revisit when a deployment actually needs it; the static path costs
nothing that would have to be undone.

**Per-caller manifest projection.** Filtering the baked file by the requesting
identity's groups requires a server in the path and gives up the static asset.
Component-level access keys carried *in* the manifest and honoured by the shell
cover the same ground without one.

## §7 — Tests

- Include-list selects exactly the named components; an unnamed component of an
  included plugin is absent.
- `views?: None` on a selection includes every public component of that plugin.
- A selection naming an unknown plugin or component fails, with the offending
  name in the message.
- The baked entry for a plugin is byte-identical to that plugin's
  `Platform_ComponentDefinitions` entry when the include-list names everything —
  the anti-drift assertion for §4.
- `internalQueryables` survives the bake for a referenced Internal view.
- Absent declaration ⇒ no file written, and the rest of the deploy's output is
  unchanged.
