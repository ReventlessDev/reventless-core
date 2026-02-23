// In-memory EventTopic publisher.
// The resource name doubles as the bus topic key that EventCollectorChannel subscribes to.

module Make = (Bus: InMemory_Bus.T) => {
  let make: Reventless.EventTopic_Adapter.publisherMaker = (~name, ~storageResources as _, ~opts as _) => {
    {
      resources: [
        {
          service: "InMemory"->Pulumi.Output.make,
          name: name->Pulumi.Output.make,
          id: name->Pulumi.Output.make,
          urn: name->Pulumi.Output.make,
          info: ""->Pulumi.Output.make,
        },
      ],
      publishJson: (
        (service, meta, json) => Bus.publishEvent(name, service, meta, json)
      )->Pulumi.Output.make,
    }
  }
}
