module type Spec = {
  module ReadModelSpec: Reventless.ReadModel.Spec
  let operations: QueryDb.operations<string, ReadModelSpec.state>
}

module Make = (
  ReadModelSpec: Reventless.ReadModel.Spec,
  Mappings: Reventless.Projection.Mappings with module Target := ReadModelSpec,
  Spec: Spec with module ReadModelSpec = ReadModelSpec,
) => {
  module EventProjector = ProjectionMapper.Make(ReadModelSpec, Mappings)

  let eventsHandler = jsons => {
    let eventCount = jsons->Array.length
    jsons
    ->Array.mapWithIndex((json, idx) => {
      let idx = idx + 1
      let sourceName = (json->Message.decode(Reventless.Message.contextSchema)).meta.service
      Console.log2(
        `ReadModel ${ReadModelSpec.name}: handling event ${idx->Int.toString}/${eventCount->Int.toString} from ${sourceName}:`,
        json,
      )
      json->EventProjector.map(~sourceName=Some(sourceName))
    })
    ->Array.flat
    ->Projection.handleActions(Spec.operations, ReadModelSpec.subIdConfig)
  }
}
