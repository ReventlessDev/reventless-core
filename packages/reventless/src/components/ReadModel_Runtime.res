module Make = (
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
) => {
  module EventProjector = ProjectionMapper.Make(Spec, Mappings)

  let eventsHandler = (primitives, jsons) => {
    let eventCount = jsons->Belt.Array.length
    jsons
    ->Belt.Array.mapWithIndex((idx, json) => {
      let idx = idx + 1
      let sourceName =
        json
        ->ReventlessSpec.Message.context_decode
        ->Belt.Result.map(context => context.meta.service)
        ->Belt.Result.getWithDefault("")
      Js.log2(
        `ReadModel: handling event ${idx->Belt.Int.toString}/${eventCount->Belt.Int.toString} from ${sourceName}:`,
        json,
      )
      json->EventProjector.map(~sourceName=Some(sourceName))
    })
    ->Belt.Array.concatMany
    ->Projection.handleActions(primitives, Spec.subIdConfig)
  }
}
