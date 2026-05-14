# Plan: CloudFront UI Fragments — Core

**Status: ✅ COMPLETE**

**Sibling plan:** `reventless-ui: docs/plans/cloudfront-ui-fragments-ui.md` — host shell construction.
**Prerequisite:** none.
**Blocks:** sibling plan step 1 needs the `Platform_UIFragments` GraphQL query from step 1 below.

## Scope

Make AWS deployments support the same Auto UI flow that already works on the in-memory platform: the host shell discovers plugin schemas and any per-plugin `remoteEntryUrl`s via GraphQL at runtime, then renders pages and panels generically.

**Default for every plugin: no UI files.** The host shell renders Auto UI from `Platform_UIDefinitions` (schemas) without any plugin bundle. Per-plugin `ui/` folders, federation `exposes`, and custom `remoteEntry.js` artefacts are an opt-in escape hatch, not a baseline requirement, and are deferred until a real example needs them.

This plan covers (a) the GraphQL query, (b) the host-shell hosting infrastructure, and (c) cache discipline on the bundle CDN. It does **not** cover the host shell React app or the federation runtime — see the UI sibling plan.

## Steps

### 1. Add `Platform_UIFragments` GraphQL query — ✅ done

**Commit:** `cf1ae27d1`

- New `reventless-core/src/admin/Platform_UIFragmentsApi.res` with SDL types (`Platform_UIFragmentEntry`, `Platform_UIPanel`, `Platform_UIMenuEntry`, `Platform_UIPage`) and the encoder `encodeUIFragmentEntry`. Mirrors the pattern in `Platform_UIDefinitionsApi.res` so AWS and in-memory return byte-identical JSON.
- `AdminApi.baseFragment` stitches both `Platform_UIDefinitionsApi.sdlTypes` + `sdlQueryField` and `Platform_UIFragmentsApi.sdlTypes` + `sdlQueryField`.
- In-memory: resolver added in `reventless-in-memory/src/Platform.res`. Reads from the existing `UIFragmentRegistry` QueryDb (already seeded), parses each row via `S.parseOrThrow` against `UIFragmentRegistryReadModelSpec.stateSchema`, encodes via the shared encoder.
- AWS: provisioned `UIFragmentRegistryReadModel` (via `ReadModel_Builder_NoResolver.Make(UIFragmentRegistryReadModelSpec, UIFragmentRegistryReadModelMappings)`) and added `Platform_UIFragments_Lambda.res` (scans the read model's DynamoDB table, returns rows verbatim). Lambda mounted in both unified (`makePlatform`) and split (`deployPlatform`) modes alongside `Platform_UIDefinitions_Lambda`.
- Tests: 10 in `reventless-core/tests/admin/Platform_UIFragmentsApiTest.res`. Existing `UIFragmentRegistryProjectionTest` covers register/update/deregister event flow.

> **Gate:** UI sibling plan step 1 can start once this is merged.

### 2. (Skipped) Per-plugin `ui/` template

**Status:** dropped. Auto UI in the host shell renders plugins from their `Platform_UIDefinitions` schemas without any per-plugin bundle. A plugin only ships a `ui/` folder when it explicitly opts out of Auto UI — none of the current examples do.

If/when a plugin needs custom UI, the opt-in mechanism would land alongside the first real use case (template package + generator support — see step 3).

### 3. (Deferred) Generator opt-in for custom UI

**Status:** deferred until a plugin actually needs custom UI. The shape this would take is documented here for posterity:

- Extend `plugin.json` schema (`reventless-spec/src/generator/Config.res`) with an optional `uiBundle` block: `{ assetsDir, bundleVersion?, spaFallback?, envVar? }`.
- Extend `renderAwsWrapper` (`reventless-spec/src/generator/Codegen.res`) so that when `uiBundle` is set, the generated `*-aws/src/Plugin.res` emits a `Plugin_Stack.makeUiBundleDistribution(...)` call and feeds its `distributionUrl` to `Composition.make(~uiBundleUrl=...)`. Absent block ⇒ today's shape unchanged (back-compat).
- Composition's `~uiBundleUrl` signature widens to accept `Pulumi.Output.t<string>`; in-memory lifts plain strings via `Pulumi.Output.make`.

No example wires this up because Auto UI handles all the current plugins. Implement when the first opt-in case arrives, with its concrete requirements driving the exact shape.

### 4. Host the static host-shell SPA from `platform-aws` — ✅ done

**Commit:** `529ae4f4b`

- New `hostUiBundleConfig` type in `reventless-infra/src/types/Platform.res` + optional `~hostUiBundle: hostUiBundleConfig=?` parameter on `deployPlatform`. Back-compat: omitting the parameter leaves the platform stack unchanged.
- AWS implementation: when `~hostUiBundle` is `Some(_)`, the platform stack calls `Plugin_Stack.makeUiBundleDistribution(~pluginId="host-ui", ~spaFallback=true, …)`, uploads a `config.json` with the resolved `domainApiEndpoint` + `region` + `authMode: "anonymous"` as a separate `S3.BucketObject`, and exports `hostShellUrl`.
- In-memory: signature widened to match; the value is ignored (host shell runs under `vite dev` against the in-process GraphQL server in local dev).
- Example wired in `examples/online-shop-hybrid/platform-aws/src/Main.res` — points `assetsDir` at the sibling `reventless-ui/reventless/host-shell/dist`.
- `authMode` is hardcoded to `"anonymous"`. Cognito wiring lands separately via `host-ui-login-core.md`; that plan will widen the `hostUiBundleConfig` record (or add platform-level Cognito outputs) and switch `authMode` to `"cognito"`.

> Production users wanting an independent host-ui deploy cadence (separate team, separate `pulumi up`) can later extract this into a standalone `host-ui-aws` package — a small refactor that adds a `Pulumi.StackReference` reading the platform outputs.

### 5. Short-TTL cache behaviors in `makeUiBundleDistribution` — ✅ done

**Commit:** `300964bea`

- Added `orderedCacheBehavior` type + `orderedCacheBehaviors` field to the `rescript-pulumi-aws` CloudFront bindings (they previously only exposed `defaultCacheBehavior`).
- `Plugin_Stack.makeUiBundleDistribution` now layers ordered cache behaviors using the AWS-managed `CachingDisabled` policy (`4135ea2d-6df8-44a3-9df3-4b5a84be39ad`, TTL 0) on top of the existing `CachingOptimized` default:
  - `/remoteEntry.js` — always (federation manifest)
  - `/index.html`, `/config.json` — only when `~spaFallback=true` (SPA shells)
- Hashed asset chunks keep the default `CachingOptimized` policy since their URL changes on every build.

### 6. Write `docs/guides/ui-fragments-deployment.md` — ✅ done

**Commit:** see the commit that moves this plan to `done/`.

The guide covers the Auto UI flow end-to-end:
- Architectural overview (host shell → `Platform_UIFragments` + `Platform_UIDefinitions` → render).
- How `plugin.makeAutoUIManifest` derives panel/page `fragmentId`s from aggregate and read-model spec names.
- The AWS deployment story: how `platform-aws` hosts the host shell, what `config.json` contains, how to flip `authMode`.
- The local dev story: in-memory platform + `vite dev` of the host shell against the in-process GraphQL server.
- The opt-in escape hatch (per-plugin `ui/` bundle) — listed as a deferred mechanism so callers know where the seam is when they need it.

Ordering replication: not needed — no plugin ships a per-plugin `ui/` folder.

## Out of scope for this plan

- React shell, AuthProvider, login UI — `reventless-ui: docs/plans/cloudfront-ui-fragments-ui.md` and `reventless-ui: docs/plans/host-ui-login-ui.md`.
- Cognito UserPool, AppSync auth mode flip — `reventless-core: docs/plans/host-ui-login-core.md`.
- Cross-origin CORS hardening — comes naturally if the host and plugin distributions share a parent CloudFront; otherwise a per-plugin CORS allow-listing pass is needed and is deferred.
- The generator opt-in mechanism for custom UI (step 3) — deferred until a real use case lands.
