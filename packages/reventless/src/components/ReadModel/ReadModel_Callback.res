module type Spec = {
  module ReadModelSpec: ReventlessSpec.ReadModel_Spec.T
  let operations: QueryDb.operations<string, ReadModelSpec.state>
}

module Make = (
  ReadModelSpec: ReventlessSpec.ReadModel_Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := ReadModelSpec,
  Spec: Spec with module ReadModelSpec = ReadModelSpec,
) => {
  module EventProjector = ProjectionMapper.Make(ReadModelSpec, Mappings)

  let eventsHandler = jsons => {
    let eventCount = jsons->Belt.Array.length
    jsons
    ->Array.mapWithIndex((json, idx) => {
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
    ->Array.flat
    ->Projection.handleActions(Spec.operations, ReadModelSpec.subIdConfig)
  }
}
