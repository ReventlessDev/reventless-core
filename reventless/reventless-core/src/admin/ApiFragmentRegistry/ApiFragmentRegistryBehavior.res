@@reventless.behavior(ApiFragmentRegistrySpec)

// NOTE: no `open Reventless.Plugin` — it would shadow the `encoded`/`protocol` labels reused
// below when building the fragment snapshot (warning 45). The two Plugin types are qualified.

// The current fragment for a plugin name plus its target API and the last recorded push
// outcome (kept only to dedupe at-least-once redelivery of RecordApiFragmentPush).
type registryEntry = {
  fragment: Reventless.Plugin.apiSchemaFragment,
  apiTarget: Reventless.Plugin.apiTarget,
  lastPush: option<(bool, string, string)>, // (ok, message, at)
}

// Singleton aggregate: the WHOLE registry, keyed by pluginId, in one consistency boundary.
type state = {entries: dict<registryEntry>}

let initialState = {entries: Dict.make()}

// Framework-internal aggregate outside an Aggregate/ folder — the Behavior.T snapshot/counter
// fields are satisfied manually (mirrors PluginBehavior). The registry's history is short
// (deploy-frequency writes), so persisted snapshots would buy nothing.
let snapshot = None
let atomicCounter = None

// Immutable dict updates (no reliance on Dict.copy/Dict.delete): rebuild via toArray/fromArray
// so evolve never mutates the replayed state.
let entriesWith = (entries: dict<registryEntry>, pluginId, entry) =>
  entries
  ->Dict.toArray
  ->Array.filter(((k, _)) => k != pluginId)
  ->Array.concat([(pluginId, entry)])
  ->Dict.fromArray

let entriesWithout = (entries: dict<registryEntry>, pluginId) =>
  entries->Dict.toArray->Array.filter(((k, _)) => k != pluginId)->Dict.fromArray

let evolve = (state, event) =>
  switch event {
  | ApiFragmentRegistered({pluginId, fragment, apiTarget}) => {
      entries: state.entries->entriesWith(pluginId, {fragment, apiTarget, lastPush: None}),
    }
  | ApiFragmentUpdated({pluginId, newFragment, apiTarget}) => {
      entries: state.entries->entriesWith(pluginId, {fragment: newFragment, apiTarget, lastPush: None}),
    }
  | ApiFragmentDeregistered({pluginId}) => {entries: state.entries->entriesWithout(pluginId)}
  | ApiFragmentPushRecorded({pluginId, ok, message, at}) =>
    switch state.entries->Dict.get(pluginId) {
    | Some(entry) => {
        entries: state.entries->entriesWith(pluginId, {...entry, lastPush: Some((ok, message, at))}),
      }
    | None => state
    }
  // Derived echo — no fold change.
  | ApiSchemaComputed(_) => state
  }

// The consistent registry snapshot AFTER the triggering change — one entry per registered plugin.
let snapshotOf = (entries: dict<registryEntry>): array<ApiFragmentRegistrySpec.fragmentSnapshotEntry> =>
  entries
  ->Dict.toArray
  ->Array.map(((pluginId, e)) => {
    ApiFragmentRegistrySpec.pluginId,
    encoded: e.fragment.encoded,
    protocol: e.fragment.protocol,
    apiTarget: e.apiTarget,
  })

// Emit the fact event plus ApiSchemaComputed{snapshot} folded from the POST-change state, so the
// reactive push SideEffect stitches from consistent state. Idempotent no-ops emit nothing (and
// therefore no push). RecordApiFragmentPush records the outcome only — it changes no fragments,
// so it emits no ApiSchemaComputed (which also avoids a recompute loop).
let decide = (state, command) => {
  let withSchema = (fact: ApiFragmentRegistrySpec.event) => {
    let next = evolve(state, fact)
    Ok([fact, ApiSchemaComputed({snapshot: snapshotOf(next.entries)})])
  }
  switch command {
  | RegisterApiFragment({pluginId, fragment, apiTarget, at}) =>
    switch state.entries->Dict.get(pluginId) {
    | None => withSchema(ApiFragmentRegistered({pluginId, fragment, apiTarget, at}))
    // Idempotent: an unchanged re-registration (same fragment AND same target — a redeploy
    // carrying the same schema, or a version supersession that didn't change the SDL) emits
    // nothing. A target change with an identical fragment IS meaningful (the fields move between
    // the Domain and Platform APIs), so it is not a no-op.
    | Some({fragment: current, apiTarget: currentTarget})
      if current == fragment && currentTarget == apiTarget =>
      Ok([])
    | Some({fragment: current}) =>
      withSchema(
        ApiFragmentUpdated({pluginId, previousFragment: current, newFragment: fragment, apiTarget, at}),
      )
    }
  | DeregisterApiFragment({pluginId}) =>
    switch state.entries->Dict.get(pluginId) {
    | None => Ok([]) // idempotent — nothing registered
    | Some(_) => withSchema(ApiFragmentDeregistered({pluginId: pluginId}))
    }
  | RecordApiFragmentPush({pluginId, ok, message, at}) =>
    switch state.entries->Dict.get(pluginId) {
    | None => Ok([]) // fragment deregistered in the meantime — nowhere to record
    // Idempotent: an at-least-once redelivery carries the identical payload.
    | Some({lastPush: Some((lastOk, lastMessage, lastAt))})
      if lastOk == ok && lastMessage == message && lastAt == at =>
      Ok([])
    | Some(_) => Ok([ApiFragmentPushRecorded({pluginId, ok, message, at})])
    }
  }
}
