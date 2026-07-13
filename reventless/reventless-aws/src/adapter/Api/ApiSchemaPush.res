// ApiSchemaPush — the admin reactive schema-push SideEffect
// (docs/plans/event-sourced-fragment-registries.md § Reactive writer design).
//
// Source = the ApiFragmentRegistry singleton aggregate. On every ApiSchemaComputed
// { snapshot } (emitted by the aggregate behaviour alongside each ApiFragment* fact,
// carrying the WHOLE consistent per-plugin fragment set), this hands the snapshot to
// the runtime-pure push engine (ApiSchemaPush_Runtime.mjs), which stitches one
// AWS-decorated schema per target API, pushes each behind the shrink guard, and writes
// the outcome back via RecordApiFragmentPush.
//
// The generic SideEffect.T context (`queryEngine`) is unused: this bespoke platform
// side effect self-acquires its config (API ids, split flag, command-topic URL) from
// Lambda env injected by the admin SideEffectHandler (~extraEnvVars). The push module
// is loaded via dynamic import so no @aws-sdk / provider code is statically captured
// beyond what the SideEffectHandler Lambda already bundles (runtime-purity — see
// reference_pulumi_leaks_into_lambda_runtime_graph).
// `include` (not a bare `module Source = …` alias) is deliberate. SideEffectHandler_Callback
// reads Source.{name,eventSchema,Id} reflectively off this module's compiled export at cold
// start, but ApiSchemaPush only uses Source at the TYPE level (Source.event, Source.Id.t,
// Source.fragmentSnapshotEntry) — a bare module alias is dead-shaken by ReScript to
// `let Source;` (undefined), crashing the handler with "Cannot read properties of undefined
// (reading 'eventSchema')". `include` materialises the module's runtime values into the export
// while keeping full type transparency for the pattern match below.
module Source = {
  include ReventlessCore.ApiFragmentRegistrySpec
}

let moduleUrl: string = %raw(`import.meta.url`)

type jsEntry = {pluginId: string, encoded: string, protocol: string, apiTarget: string}

let pushApiSchema: array<jsEntry> => promise<unit> = %raw(`
  async function (snapshot) {
    const mod = await import("@reventlessdev/reventless-aws/src/adapter/Runtime/ApiSchemaPush_Runtime.mjs");
    await mod.pushApiSchema(snapshot);
  }
`)

let execute = async (
  _id: Source.Id.t,
  _meta: Reventless.Message.meta,
  event: Source.event,
  _queryEngine: Reventless.QueryEngine.operations,
) =>
  switch event {
  | ApiSchemaComputed({snapshot}) =>
    let jsSnapshot = snapshot->Array.map((e: Source.fragmentSnapshotEntry) => {
      pluginId: e.pluginId,
      encoded: e.encoded,
      protocol: e.protocol,
      apiTarget: switch e.apiTarget {
      | Reventless.Plugin.Domain => "Domain"
      | Reventless.Plugin.Platform => "Platform"
      },
    })
    await pushApiSchema(jsSnapshot)
  // Fact events are handled via the ApiSchemaComputed echo (which carries the
  // consistent snapshot); the write-back and lifecycle facts are no-ops here.
  | ApiFragmentRegistered(_)
  | ApiFragmentUpdated(_)
  | ApiFragmentDeregistered(_)
  | ApiFragmentPushRecorded(_) => ()
  }
