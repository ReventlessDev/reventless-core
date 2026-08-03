# Plan: a deployment can choose what the shell *does*, not only what it points at

**Date:** 2026-08-03
**Status:** IMPLEMENTED (steps 1–5) — awaiting the on-AWS half of Verification, which needs a
user-run `pulumi up`. See [Implementation](#implementation) at the foot.
**Repos:** reventless-core only. The reader half already exists, is released, and is pinned; this
plan writes nothing in the UI repo and needs no release there.
**Builds on:** [semantic-geo-point.md](./semantic-geo-point.md) — whose steps 1–3 landed the declared
point, and whose companion in the UI repo (`autoui-geo-point-declared.md`) landed the role that reads
it. Both are released. This plan is the reason neither is visible.

## The finding

The hybrid example's `Customers` view shows no map, and the `SetLocation` command form shows no map
picker. None of the usual suspects is the cause — every one of them is done and shipped:

| Half | Where | State |
|---|---|---|
| the declared point | `Customer.location: GeoPoint.t`, `Customers.location: option<GeoPoint.t>` | released (`bfe2f9024`) |
| seeded coordinates | [HybridSeedData.res:213](../../examples/online-shop-hybrid/seed-data/src/HybridSeedData.res#L213) | present |
| the role that reads a declared point | `Mappable` capability, `geoSource` | released in host-shell `3.0.0-alpha.53` |
| the pin the hybrid runs | [platform-aws/package.json:21](../../examples/online-shop-hybrid/platform-aws/package.json#L21) | `3.0.0-alpha.53` — the lockstep constraint is satisfied |
| the geocoder | place index at [Main.res:13](../../examples/online-shop-hybrid/platform-aws/src/Main.res#L13) → `Geocoder_AwsLocation` Function URL → `geocoderEndpoint` in config.json | provisioned |

The map is an **opt-in chunk**. The shell's registrar dynamic-imports `@reventlessdev/reventless-map`
and calls `MapMode.init` only when `config.json`'s `viewModes` names `"map"` — that indirection is
deliberate and worth keeping, because it is what stops every deployment downloading maplibre-gl.

**Nothing in this repo ever sets `viewModes`.** `grep -rn viewModes` over reventless-core returns zero
hits — not in code, not in a plan, not in a doc. The default is `[]`, so the chunk is never fetched,
`MapMode.init` never runs, and the mode registers nothing.

And `init` registers **two** things — the map view mode *and* the geo-point command input. So one
unset key hides both halves of the feature: no Map toggle on the view, and no picker on the form.

### The geocoder is worse than unused

`Geocoder.fromEndpoint(config.geocoderEndpoint)` is called *inside* the dynamically-imported map
chunk. So the hybrid provisions an AWS Location place index and a public Lambda Function URL, writes
the endpoint into config.json — and no shipped browser ever calls any of it. The deployment pays for
a service that the same missing key makes unreachable.

### It is not one field — it is a whole category

The shell's `Config.res` reads a good deal more than the deploy writes. The deploy's writer
([Platform.res:2041–2089](../../reventless/aws/src/Platform.res#L2041-L2089)) emits the ones it
**computes** — `apiEndpoint`, `platformApiEndpoint`, `region`, `authMode`, the two Cognito ids,
`liveUpdates`, the events endpoints, `geocoderEndpoint`. Every key that is a **choice** rather than a
computation is missing, and there is no field on `hostUiBundleConfig`
([Platform.res:302–328](../../reventless/infra/src/types/Platform.res#L302-L328)) through which a
Pulumi program could offer one:

| Key the shell reads | Emitted by the deploy? | Reachable from a stack? |
|---|---|---|
| `apiEndpoint`, `platformApiEndpoint`, `region`, `authMode`, cognito ids, `liveUpdates`, events endpoints, `geocoderEndpoint` | yes — computed | n/a |
| `viewModes` | **no** | **no** |
| `mapStyle`, `graphLayout` | **no** | **no** |
| `accessTiers`, `platformName`, `assetOrigins`, `uiHintsUrl` | **no** | **no** |

So the shape of the bug is: *config.json is an output of the deploy and never an input to it.* A
deployment can be told where its API is; it cannot say what kind of app it wants to be.

## Decisions

### D1. `viewModes` is a typed list, not `array<string>`

The wire form is `["map"]` and the temptation is to pass exactly that. A string array reproduces the
failure this plan exists to fix: `"viewMods"` — or `"Map"`, or a mode renamed one release later —
type-checks, deploys, and produces a shell with no map and no error anywhere. That is a name guess
standing in for a declaration, in a repo whose last three plans were about replacing exactly that.

So the deploy declares a variant, following `capability`'s precedent in the same module (a closed
variant, record payloads, one `toString` owning the wire spelling):

```rescript
type mapOptions = {style?: string}
type graphOptions = {layout?: string}
type viewMode =
  | Map(mapOptions)
  | Graph(graphOptions)
```

The **cost is honest and worth stating**: the mode set is closed in core, so a third mode shipping in
the UI repo cannot be turned on until core releases. Accepted because both existing modes are stable
and in-repo, and because the alternative trades a compile error for a silent blank view. The escape
hatch is named under Follow-ups, not built.

**Settle on contact:** whether `Map({})` is legal ReScript for an all-optional inline record. If it is
not, the arms take a constructor helper (`Platform.mapMode(~style=?, ())`) rather than a positional
`option`; either way the call site must be able to say "map, defaults" in one token.

### D2. Per-mode options ride on their mode; the wire shape stays flat

`mapStyle` and `graphLayout` are flat siblings of `viewModes` in config.json, and they stay that way —
the shell is released and reads them there. But on the *deploy* side they are payloads of their arm,
so `mapStyle` set with the map off is unrepresentable rather than merely useless. The writer flattens
on the way out. One shape for the declaration, one for the wire, and the flattening in one function.

### D3. One untyped passthrough for the rest — `shellConfig`

`accessTiers`, `assetOrigins`, `uiHintsUrl` and `platformName` are in the same position as `viewModes`
and none of them is this plan's subject. Typing each one here would mean core re-declaring the shell's
config schema field by field, and releasing in lockstep every time the UI adds a knob — the precise
cross-repo cost the geo wave just paid, re-incurred forever.

So: `shellConfig?: dict<JSON.t>`, merged into config.json **under** the computed keys. These are keys
the *shell* owns and core has no opinion about; passing them through is not core declaring them.

Both mechanisms in one file is a smell worth answering directly: `viewModes` is typed because getting
it wrong silently deletes a feature, and it is the one key with that property. The rest fail visibly
or harmlessly. Type what bites.

**A collision is a deploy-time failure, not a silent overwrite.** If `shellConfig` carries a key the
deploy computes (`apiEndpoint`, say), the deploy fails naming the key. Merging silently either way
produces an app pointed at the wrong API with nothing in the diff to say so.

### D4. Local carries and ignores, exactly as it does today

`reventless-local`'s `deployPlatform` ignores `~hostUiBundle` entirely — the shell is served by the
dev server, not from a CDN — and already carries `geocoderPlaceIndex` and `uploadBucket` only to
satisfy the shared `Platform.T` signature. The two new fields join them on the same terms and with
the same comment.

The asymmetry this leaves is real and should not be papered over: **turning the map on for local dev
means editing the host-shell package's own `public/config.json`**, which its dev guide documents. So
after this plan the deployed hybrid gets a map from its stack, and the local hybrid gets one from a
hand edit. Closing that is a separate seam (the local platform would have to serve config.json at
all) and is listed under Follow-ups.

## Steps

**1 — the declaration (`reventless/infra`).** `viewMode` / `mapOptions` / `graphOptions` in
`ReventlessInfra.Platform`, beside `capability`; `viewModes?: array<viewMode>` and
`shellConfig?: dict<JSON.t>` on `hostUiBundleConfig`, each with the comment style its neighbours use
(what it does, what unset means).

**2 — the writer, extracted so it can be tested (`reventless/aws`).** The field assembly currently
lives inside a `Pulumi.Output.apply` in `deployPlatform`, which is why no test asserts a single key of
it. Lift it to a pure function — `ShellConfig.fields(~computed, ~viewModes, ~shellConfig)` returning
the dict — following the `_Ops` split discipline the runtime modules already use. The `apply` then
calls it. Mirror the two new fields on the AWS copy of `hostUiBundleConfig` and thread them in;
flatten per-mode options per D2; fail on a collision per D3.

**3 — local carries them (`reventless/local`).** Two fields on its `hostUiBundleConfig`, ignored,
commented as D4.

**4 — the hybrid opts in.** In [platform-aws/src/Main.res](../../examples/online-shop-hybrid/platform-aws/src/Main.res):
`~hostUiBundle={viewModes: [Map({})], geocoderPlaceIndex: placeIndex, uploadBucket}`. The comment
above `placeIndex` already says it "backs the geo-point command input's address search" — it should
now also say that the input only exists because the map mode is named here, so a future edit that
drops one and keeps the other reads as the mistake it is. Leave `style` unset: the mode's built-in
demo tiles are the honest default for an example, and a real style URL is a per-deployment key with
a real account behind it.

**5 — the docs catch up.** `packages/doc/docs-infrastructure/ui-fragments-deployment.md`
[§ What `platform-aws` provisions](../../packages/doc/docs-infrastructure/ui-fragments-deployment.md)
lists config.json's keys and is already stale (no `liveUpdates`, no events endpoints, no
`geocoderEndpoint`). Bring the list current and add the two new inputs with the one sentence that
matters: naming `Map` is what makes both the map view and the map-backed command input exist.

## Verification

- **`ShellConfig.fields` is unit-tested** — the point of step 2's extraction. Cases: no `viewModes` ⇒
  the key is absent and the dict is byte-identical to today's (the "costs a non-map deployment
  nothing" claim, asserted rather than argued); `Map({})` ⇒ `"viewModes": ["map"]` and **no**
  `mapStyle` key; `Map({style})` ⇒ both, flat; `shellConfig` keys land; a `shellConfig` key that
  collides with a computed one fails, naming the key.
- **The hybrid's config.json carries `viewModes` after a `pulumi up`** — read the deployed object.
  (`pulumi up` is user-owned; it provisions billable resources.)
- **Browser, against the deployed hybrid** — the three things one unset key was hiding, and the order
  matters because each is a different half:
  1. the **Map toggle** appears on the Customers view and pins the seeded customers — with the
     unlocated ones absent rather than stacked at (0, 0);
  2. the **picker mounts** on the `SetLocation` form and the submitted mutation carries the point;
  3. **address search answers** through AWS Location — the first exercise this path has ever had.
- Checks 2 and 3 are the two open items the UI repo's deploy-verification tracker has been holding;
  this plan is what makes them runnable, and they should be struck there when they pass.
- **Zero warnings** after a full build, and no `.res.mjs` deletions (`git ls-files --deleted`).

## Out of scope

- **Using the other choice-shaped keys.** `accessTiers`, `assetOrigins`, `uiHintsUrl` and
  `platformName` become *reachable* via D3 and are not *set* by anything here. Making the hybrid use
  one is its own small change with its own reason.
- **A real map style.** Tiles and glyphs are an account and a bill; the example ships the demo style.
- **Server-side geocoding.** Turning a customer's `address` into a point at command time is the
  `Address` composite's job and is a follow-up in `semantic-geo-point.md`. Here a point is entered by
  clicking the picker.
- **Graph mode for the hybrid.** The arm exists after step 1; whether the example wants it is a
  separate question about the example.
- **Local serving config.json.** Per D4.

## Follow-ups

- **An escape hatch on `viewMode`** the first time a mode ships that core does not know about. `Other(string)`
  next to the typed arms keeps D1's guarantee for the modes core does know and unblocks the one it
  does not; adding it before that day would just be `array<string>` with extra steps.
- **The local platform serves config.json**, so `viewModes` reaches local dev the same way it reaches
  a deploy and the D4 asymmetry closes.
- **A config.json contract test across the two repos** — the shell's reader and this writer agree on
  key names by inspection today, and the whole finding above is what that costs when they quietly
  stop agreeing.

## Implementation

| Step | Landed in |
|---|---|
| 1 — the declaration | `mapOptions` / `graphOptions` / `viewMode` / `viewModeToString` beside `capability` and `geocoderIndex` in [reventless/infra/src/types/Platform.res](../../reventless/infra/src/types/Platform.res); `viewModes?` + `shellConfig?` on `hostUiBundleConfig` |
| 2 — the writer, extracted | [reventless/aws/src/util/Util_ShellConfig.res](../../reventless/aws/src/util/Util_ShellConfig.res) (`fields`, `modeOptions`), named for the `Util_*` convention of the folder it sits in; the `Pulumi.Output.apply` in `deployPlatform` now assembles `computed` and calls it |
| 3 — local carries them | [reventless/local/src/Platform.res](../../reventless/local/src/Platform.res) |
| 4 — the hybrid opts in | [examples/online-shop-hybrid/platform-aws/src/Main.res](../../examples/online-shop-hybrid/platform-aws/src/Main.res) — `viewModes: [Map({})]` |
| 5 — the docs | `packages/doc/docs-infrastructure/ui-fragments-deployment.md` — key list brought current, new *Choosing what the shell does* subsection |

`Map({})` is legal — D1's "settle on contact" question resolved in favour of the inline record; no
constructor helper was needed.

**Done:** [reventless/aws/tests/Util_ShellConfigTest.res](../../reventless/aws/tests/Util_ShellConfigTest.res)
covers all five cases (5 assertions, green). Full root build clean — zero warnings, no `.res.mjs`
deletions; the hybrid's tracked `Main.res.mjs` re-emitted with the new arm. `reventless-aws` +
`reventless-local` suites green (991 tests).

**Still open, and user-owned:** the deployed checks — `pulumi up`, then config.json carrying
`viewModes`, then the three browser checks. The two UI-repo tracker items stay open until those run.
