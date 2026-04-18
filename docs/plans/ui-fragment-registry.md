# Plan: UI Fragment Registry — Platform_Admin Extension

**Date:** 2026-04-18

---

## Goal

Extend `Platform_Admin` to carry a UI fragment manifest alongside the existing API schema manifest in each plugin's `pluginDefinition`. This enables the dashboard shell to dynamically register and deregister UI panels and pages as plugins come and go — without a shell rebuild.

This is the backend half of the micro-frontend architecture. The frontend half (the `PanelRegistry`, `PageRegistry`, and `register()` API) is implemented in the companion UI library.

---

## Background

`Platform_Admin` already solves this problem for the GraphQL API layer: when a plugin connects, its `apiSchemaFragment` is stitched into the platform's unified schema. When the plugin disconnects, its types are removed. The unified API reflects exactly the plugins currently running, with no manual step.

UI fragment registration follows the same pattern. The plugin sends a manifest of its UI fragments (panel IDs and CDN bundle URL) with its `Connect` command. `Platform_Admin` stores the manifest in a `UIFragmentRegistry` read model and fires lifecycle events. The dashboard shell subscribes to registry changes via AppSync and loads or unloads bundles dynamically.

| Aspect | GraphQL schema stitching | UI fragment stitching |
|--------|--------------------------|----------------------|
| What is registered | SDL type definitions + resolver bindings | Panel manifest + bundle URL |
| Submitted via | `pluginDefinition.apiSchemaFragment` | `pluginDefinition.uiFragments` |
| Storage | Schema projection | `UIFragmentRegistry` read model |
| Lifecycle events | Implicit in plugin lifecycle | `UIFragmentRegistered` · `UIFragmentUpdated` · `UIFragmentDeregistered` |
| Disconnect trigger | Liveness timeout | Liveness timeout |
| Consumer notification | Schema introspection on next request | AppSync subscription `onUIFragmentChange` |
| Consumer action | Re-execute queries against updated schema | Fetch bundle from CDN, call `registry.register()` |

---

## Context: Build-Time vs Runtime Registration

The micro-frontend architecture has two delivery modes:

- **Build-time registration** — panels are npm packages imported at dashboard build time. The shell is a static SPA. No backend changes are needed; the dashboard works without anything in this plan.
- **Runtime registration** — panels are loaded from CDN after deploy, driven by backend lifecycle events. This is what this plan implements.

Everything in this plan is prerequisite for runtime registration and has no effect on build-time registration. The two modes are additive — a deployment can start with build-time registration and migrate to runtime registration by implementing this plan.

---

## Step 1: Extend `pluginDefinition` with UI Fragment Manifest

### 1.1 New types in `PluginDefinition.res`

```rescript
// reventless-core/src/admin/PluginDefinition.res (additions)

// ── Panel fragment manifest ───────────────────────────────────────────────────

// Positions are plain strings defined by the host application.
// The consuming shell defines its own position constants (e.g. "summary", "detail").
// This library does not enumerate them.

type panelManifestEntry = {
  fragmentId: string,             // globally unique, e.g. "monitor.latency"
  title: string,
  description: string,
  positions: array<string>,
  requiredAccess: option<string>,
}

// ── Page fragment manifest ────────────────────────────────────────────────────

type menuEntry = {
  label: string,
  icon: option<string>,
  group: option<string>,          // sidebar group label; None → ungrouped
  sortOrder: int,
}

type pageManifestEntry = {
  fragmentId: string,
  title: string,
  menuEntry: menuEntry,
  requiredAccess: option<string>,
}

// ── UI fragment manifest ──────────────────────────────────────────────────────

// The CDN URL from which the browser fetches the panel bundle at runtime.
// Set to None in Phase 1 (npm-installed, no CDN). Required in Phase 2.
type uiFragmentManifest = {
  remoteEntryUrl: string,         // https://d1abc.cloudfront.net/monitor-ui@2.1.0/remoteEntry.js
  panels: array<panelManifestEntry>,
  pages: array<pageManifestEntry>,
}

// ── Extension to pluginDefinition ────────────────────────────────────────────

// Added to the existing pluginDefinition type alongside apiSchemaFragment.
// None = plugin has no UI (typical for pure backend plugins)
// uiFragments: option<uiFragmentManifest>,
```

### 1.2 Update `Plugin_Builder.res` — `withAutoUI()`

`Plugin_Builder` gains a `withAutoUI()` method. It derives `uiFragmentManifest` metadata directly from the plugin's already-registered read models and aggregates — the same schema source that the UI library's `generateFragments` uses, but without importing React or producing any React components. reventless-core must not depend on React.

The manifest contains only serialisable metadata: fragment IDs, positions, required licenses, and the CDN URL. The React components that implement the auto-generated views live in the plugin's UI bundle on CDN, which is built separately and calls `generateFragments` from the UI library at bundle load time.

```rescript
// reventless-core/src/admin/Plugin_Builder.res (addition)

// makeAutoUIManifest derives uiFragmentManifest from the plugin's read models and aggregates:
//   — each read model → panelManifestEntry at readModelPositions (caller-supplied strings)
//                        + pageManifestEntry with fragmentId "${name}.${rm.name}.list"
//   — each aggregate  → panelManifestEntry at aggregatePositions (caller-supplied strings)
//                        with fragmentId "${name}.${agg.name}.detail"
// remoteEntryUrl is the Pulumi stack output URL of the plugin's CDN bundle.
// That bundle's entry point calls generateFragments from the UI library and
// registers the resulting panelDefinition/pageDefinition arrays with the shell.
let makeAutoUIManifest: (
  ~remoteEntryUrl: string,
  ~name: string,
  ~aggregates: ...,
  ~readModels: ...,
  ~readModelPositions: array<string>=?,
  ~aggregatePositions: array<string>=?,
) => uiFragmentManifest
```

`withAutoUI` is optional — plugins with no UI do not call it. Plugins providing fully custom UI populate `uiFragments` manually (bypassing `withAutoUI`) and export their own fragment definitions from their CDN bundle.

---

## Step 2: `Platform_Admin` — Lifecycle Handling

### 2.1 New events on `Plugin` aggregate

Three new events track the UI fragment manifest through the plugin lifecycle:

```rescript
// reventless-core/src/admin/Plugin_Events.res (additions)

| UIFragmentRegistered({
    pluginId: string,
    manifest: uiFragmentManifest,
  })

| UIFragmentUpdated({
    pluginId: string,
    previousManifest: uiFragmentManifest,
    newManifest: uiFragmentManifest,
  })

| UIFragmentDeregistered({
    pluginId: string,
  })
```

### 2.2 Command handling

**`Connect` command** — when `pluginDefinition.uiFragments` is `Some(manifest)`:
- If no prior manifest exists for this plugin → emit `UIFragmentRegistered`
- If a prior manifest exists and it differs from the new one → emit `UIFragmentUpdated`
- If a prior manifest exists and it is identical → emit nothing (idempotent)

**Liveness timeout** — when a plugin's heartbeats stop and `UIFragmentDeregistered` has not yet been emitted:
- Emit `UIFragmentDeregistered`

This mirrors the existing handling of `apiSchemaFragment` — no new command types are needed.

---

## Step 3: `UIFragmentRegistry` Read Model

A read model that holds the current set of registered UI fragment manifests across all connected plugins. Used by the dashboard shell to populate the registries on startup and to re-populate after a subscription event.

### 3.1 Schema

```rescript
// reventless-core/src/admin/UIFragmentRegistry.res

type fragmentEntry = {
  pluginId: string,
  manifest: uiFragmentManifest,
  registeredAt: string,   // ISO 8601
  updatedAt: string,
}

type t = {
  fragments: Dict.t<fragmentEntry>,   // keyed by pluginId
}
```

### 3.2 Projections

| Event | Projection |
|-------|-----------|
| `UIFragmentRegistered` | Insert entry for `pluginId` |
| `UIFragmentUpdated` | Replace entry for `pluginId`, update `updatedAt` |
| `UIFragmentDeregistered` | Remove entry for `pluginId` |

### 3.3 GraphQL query

```graphql
# Exposed as part of the Platform_Admin GraphQL schema

type UIFragmentEntry {
  pluginId: ID!
  remoteEntryUrl: String!
  panels: [PanelManifestEntry!]!
  pages: [PageManifestEntry!]!
  updatedAt: String!
}

type Query {
  Admin_UIFragments: [UIFragmentEntry!]!
}
```

The dashboard shell queries `Admin_UIFragments` at startup to populate both registries before first render.

---

## Step 4: AppSync Subscription

A Source C subscription (`@aws_subscribe`) that fires whenever the fragment registry changes. The dashboard shell subscribes at startup and reacts to each push by fetching the updated registry and calling `registry.register()` or removing stale panels.

```graphql
# Platform_Admin subscription schema addition

type Subscription {
  onUIFragmentChange: UIFragmentChangeEvent
    @aws_subscribe(mutations: [
      "Platform_UIFragmentRegistered",
      "Platform_UIFragmentUpdated",
      "Platform_UIFragmentDeregistered"
    ])
}

type UIFragmentChangeEvent {
  pluginId: ID!
  changeKind: UIFragmentChangeKind!
  manifest: UIFragmentEntry   # null when changeKind is Deregistered
}

enum UIFragmentChangeKind {
  Registered
  Updated
  Deregistered
}
```

Each mutation that emits one of the three UI fragment events also triggers the `onUIFragmentChange` subscription, following the Source C pattern already established for other Platform_Admin events.

---

## Step 5: CDN Bundle Hosting (Pulumi)

Each plugin that ships UI panels provisions its own S3 bucket and CloudFront distribution for the panel bundle. The `remoteEntryUrl` in the `uiFragmentManifest` is the Pulumi stack output of this distribution.

### 5.1 New Pulumi resource in `Plugin_Stack.res`

```rescript
// reventless-core/src/pulumi/Plugin_Stack.res (addition)

// When a plugin calls withAutoUI(), the Pulumi stack provisions:
// - An S3 bucket for the panel bundle
// - A CloudFront distribution in front of it
// - Appropriate bucket policy and cache headers
// The distribution domain name is exported as a Pulumi stack output
// and passed to withAutoUI(~remoteEntryUrl=...) in the plugin definition.
let makeUiBundleDistribution: (~pluginId: string, ~bundleVersion: string) => {
  distributionUrl: Output.t<string>,
  bucketName: Output.t<string>,
}
```

The plugin's CI/CD step uploads the compiled bundle to the S3 bucket. The `distributionUrl` is used as `remoteEntryUrl` in `pluginDefinition.uiFragments`.

---

## Execution Checklist

```
Phase 1 — pluginDefinition extension ✅
  [x] 1.1  Add panelManifestEntry (positions: array<string>, requiredAccess), pageManifestEntry,
           menuEntry (group: option<string>), uiFragmentManifest types to Plugin.res (reventless-spec)
  [x] 1.2  Add uiFragments: option<uiFragmentManifest> field to pluginDefinition
  [x] 1.3  Plugin_Builder.makeAutoUIManifest() — derives manifest from registered
           aggregates and read models; ~readModelPositions and ~aggregatePositions are
           caller-supplied strings (default []); ~uiFragments=? added to Plugin.T.make
  [x]      Verify: existing plugin definitions compile without changes (field is optional)
           — 107/107 test suites, 1005/1005 tests, zero warnings

Phase 2 — Platform_Admin lifecycle handling ✅
  [x] 2.1  Add UIFragmentRegistered, UIFragmentUpdated, UIFragmentDeregistered
           to PluginSpec.res (with named payload types uiFragmentRegisteredData,
           uiFragmentUpdatedData, uiFragmentDeregisteredData)
  [x] 2.2  Handle uiFragments in Connect command — emit UIFragmentRegistered
           alongside Connected; emit UIFragmentDeregistered alongside
           Disconnected and Deactivated (from Connected state); re-connect
           via Heartbeat emits UIFragmentRegistered alongside Reconnected
  [x] 2.3  Handle liveness timeout → UIFragmentDeregistered: liveness timeout
           sends Disconnect command → Disconnected event → UIFragmentDeregistered
           emitted when pluginDefinition.uiFragments is set
  [x]      Verify: 305/305 tests pass, zero warnings. New behavior tests cover
           Connect+UIFragmentRegistered, Disconnect+Deregister, Deactivate+Deregister,
           Heartbeat-reconnect+Register, Deactivate-from-Disconnected (no double deregister).
           UIFragmentUpdated defined in schema but unreachable in current architecture
           (Connect only valid in Detected state — no prior manifest exists).

Phase 3 — UIFragmentRegistry read model ✅
  [x] 3.1  UIFragmentRegistryReadModelSpec.res — flat state type (pluginId, remoteEntryUrl,
           panels, pages, registeredAt, updatedAt); keyed by pluginId
  [x] 3.2  UIFragmentRegistryProjection.res — Registered→Set, Updated→Update,
           Deregistered→Delete; UIFragmentRegistryProjectionTest (6 tests)
  [x] 3.3  Admin_UIFragments GraphQL query — UIFragmentEntry type generated from state schema;
           resolver backed by Bus UIFragmentRegistry QueryDb; seeded from plugin outputs
           (pluginDefinition.uiFragments); MCP resource handler routes UIFragment vs Plugin
           queries by field name; 311/311 tests, zero warnings

Phase 4 — AppSync subscription ✅
  [x] 4.1  onUIFragmentChange: UIFragmentChangeEvent subscription added to AdminApi.baseFragment
           (returned from Platform_Admin.construct via adminFragment; included in AppSync SDL)
  [x] 4.2  Platform_UIFragmentRegistered/Updated/Deregistered mutations added to AdminApi.baseFragment
           with UIFragmentChangeEvent return type; UIFragmentChangeKind enum + UIFragmentChangeEvent
           type injected into admin schema types
  [x] 4.3  @aws_subscribe(mutations: [...]) wired on onUIFragmentChange; @aws_subscribe directive
           stripped by in-memory yoga (only valid in AppSync)
           In-memory: Source C PubSub bridge added in makePlatform, deployPlatform, deployPlugin
           fallback — mutation resolvers publish to "onUIFragmentChange" topic; subscription
           resolver registered; UIFragment query resolvers added to deployPlatform + deployPlugin
           fallback paths; 311/311 tests, zero warnings
           Verify (AWS): subscription fires when backend calls Platform_UIFragmentRegistered
           mutation after UIFragmentRegistered event is processed

Phase 5 — CDN bundle hosting ✅
  [x] 5.1  Plugin_Stack.makeUiBundleDistribution — private S3 bucket (BucketV2 +
           BucketPublicAccessBlock), CloudFront OAC + Distribution (CachingOptimized,
           redirect-to-https, default cert), S3 BucketPolicy scoped to distribution ARN.
           New bindings: CloudFront_OriginAccessControl, CloudFront_Distribution,
           CloudFront.res re-export, S3_BucketPolicy; S3_Bucket.t extended with
           bucketRegionalDomainName. reventless-aws/src/Plugin_Stack.res.
  [x] 5.2  Returns { distributionUrl: Output.t<string>, bucketName: Output.t<string> };
           caller exports distributionUrl as Pulumi.export("remoteEntryUrl", ...)
           and passes it to withAutoUI(~remoteEntryUrl=...)
  [ ] 5.3  Document CI/CD upload step for plugin bundle
  [ ]      Verify: remoteEntryUrl resolves to uploaded bundle from browser
```

---

## Dependencies

```
Phase 1 (pluginDefinition extension)
  └── Phase 2 (lifecycle events) — events reference uiFragmentManifest type
  └── Phase 5 (CDN) — remoteEntryUrl is a Pulumi output fed into withAutoUI()

Phase 2 (lifecycle events)
  └── Phase 3 (read model) — UIFragmentRegistry projects the lifecycle events
  └── Phase 4 (subscription) — subscription fires on the lifecycle mutations

Phase 3 and Phase 4 are independent of each other and can proceed in parallel.
```

Phases 1–4 must be complete before the dashboard shell's runtime registration can be tested end-to-end.
