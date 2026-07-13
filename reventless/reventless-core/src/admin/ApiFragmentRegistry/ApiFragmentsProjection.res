// ApiFragments projection — maps ApiFragmentRegistry aggregate events to per-plugin rows of
// the ApiFragments read model. Manual Mapping.Make form (mirrors PluginsProjection; no ppx —
// this file lives outside a ReadModel/ folder). Rows are keyed by the payload `pluginId`, not
// the (singleton) aggregate id. `ApiSchemaComputed` is the reactive push's trigger only — it
// carries no per-plugin row change, so it is Ignored here.
//
// A fragment change resets the row to "pending"; the push outcome arrives as a subsequent
// ApiFragmentPushRecorded. An Update on a deleted row (a push recorded after deregistration) is
// a no-op by Update semantics.

open Reventless.Projection
open Reventless.Message // brings the projection input record ({event, id, meta}) labels into scope

let moduleUrl: string = %raw(`import.meta.url`)

module ApiFragmentsMapping = Reventless.Projection.Mapping.Make(
  ApiFragmentRegistrySpec,
  ApiFragmentsReadModelSpec,
  {
    let project = ({event, _}) =>
      switch event {
      | ApiFragmentRegistrySpec.ApiFragmentRegistered({pluginId, fragment, apiTarget, at}) =>
        Set(
          pluginId,
          {
            ApiFragmentsReadModelSpec.pluginId,
            encoded: fragment.encoded,
            protocol: fragment.protocol,
            apiTarget,
            registeredAt: at,
            updatedAt: at,
            pushStatus: "pending",
            pushMessage: "",
            pushedAt: "",
          },
        )
      | ApiFragmentUpdated({pluginId, newFragment, apiTarget, at}) =>
        Update(pluginId, state => {
          ...state,
          encoded: newFragment.encoded,
          protocol: newFragment.protocol,
          apiTarget,
          updatedAt: at,
          pushStatus: "pending",
          pushMessage: "",
        })
      | ApiFragmentDeregistered({pluginId}) => Delete(pluginId)
      | ApiFragmentPushRecorded({pluginId, ok, message, at}) =>
        Update(pluginId, state => {
          ...state,
          pushStatus: ok ? "ok" : "error",
          pushMessage: message,
          pushedAt: at,
        })
      // Reactive push trigger only — no row change.
      | ApiSchemaComputed(_) => Ignore
      }
  },
)

module Mappings = Reventless.Projection.Mappings.Make(ApiFragmentsReadModelSpec)

let mappings: array<module(Mappings.Mapping)> = [module(ApiFragmentsMapping)]
