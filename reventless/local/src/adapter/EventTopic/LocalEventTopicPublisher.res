// In-memory EventTopic publisher.
// The resource name doubles as the bus topic key that EventCollectorChannel subscribes to.

module Make = (Bus: LocalBus.T) => {
  let make: ReventlessCore.EventTopic_Adapter.publisherMaker = (~name, ~storageResources as _, ~opts as _) => {
    let publishJson = (service, meta, json) => Bus.publishEvent(name, service, meta, json)
    let publishJsonStream: ReventlessInfra.EventTopic.publishJsonStream = stream =>
      stream
      ->Stream.grouped(10)
      ->Stream.runForEach(items =>
        Effect.promise(() =>
          items
          ->Array.map(({ReventlessInfra.EventTopic.service, meta, json}) =>
            publishJson(service, meta, json)
          )
          ->Promise.all
          ->Promise.thenResolve(_ => ())
        )
      )

    {
      resources: [
        ReventlessInfra.Adapter.make(
          ~name=name->Pulumi.Output.make,
          ~id=name->Pulumi.Output.make,
          ~urn=name->Pulumi.Output.make,
          ~service="memory:InMemory"->Pulumi.Output.make,
        ),
      ],
      publishJson: (
        (service, meta, json) => Bus.publishEvent(name, service, meta, json)
      )->Pulumi.Output.make,
      publishJsonStream: publishJsonStream->Pulumi.Output.make,
    }
  }
}
