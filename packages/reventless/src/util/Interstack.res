let coreStackReference =
  Pulumi.Config.make(Some("core"))
  ->Pulumi.Config.get("stack")
  ->Option.map(stack => stack->Pulumi.StackReference.make)

// -----------------------------------------------------------------------
// Typed, validated cross-stack queries using the reventless-interop engine.
// Replaces the previous unchecked getOutputs() casts.
//
// Return type changed from:
//   Pulumi.Output.t<array<T.outputs>>          (unchecked cast, silent wrong data)
// to:
//   Pulumi.Output.t<array<result<T.resolvedOutputs, ReventlessInterop.Compat.error>>>
//                                              (validated, explicit error on mismatch)
// -----------------------------------------------------------------------

module DefaultTaskQuery = ReventlessInterop.Query.Task.Make({
  type t = ReventlessInterop.Task.resolvedOutputs
  let requiredFields = ["name"]
  let optionalFields = ["bucketNames", "sideEffectSources"]
  let fromJson = (json: JSON.t) =>
    try Ok(json->S.parseOrThrow(ReventlessInterop.Task.resolvedOutputsSchema))
    catch {
    | exn =>
      let msg =
        exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("parse error")
      Error(msg)
    }
})

module DefaultEventMapperQuery = ReventlessInterop.Query.EventMapper.Make({
  type t = ReventlessInterop.EventMapper.resolvedOutputs
  let requiredFields = ["name", "eventCollector"]
  let optionalFields = ["counter"]
  let fromJson = (json: JSON.t) =>
    try Ok(json->S.parseOrThrow(ReventlessInterop.EventMapper.resolvedOutputsSchema))
    catch {
    | exn =>
      let msg =
        exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("parse error")
      Error(msg)
    }
})

// Typed cross-stack queries.  Each item is either Ok(resolvedOutputs) or
// Error(Compat.error) describing which field was missing or which decode failed.
let stackDependenciesTasks = DefaultTaskQuery.queryAll()
let stackDependenciesEventMappers = DefaultEventMapperQuery.queryAll()

// Merge local items with successfully queried remote items.
// Remote errors are silently dropped; inspect queryAll() directly if you need them.
let mergeTasks = DefaultTaskQuery.mergeWith
let mergeEventMappers = DefaultEventMapperQuery.mergeWith
