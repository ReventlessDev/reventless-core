module Make = (
  Config: Config.T,
  QueryDbStorage: QueryDb.Adapter.Storage with type api = Config.api and type role = Config.role,
  Handler: Counter_Adapter.Handler,
): Counter.T => {
  let construct = (
    ~counterEventsHandler: Counter.counterEventsHandler,
    ~ttl: option<int>,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let opts2 = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    module ReferencesSpec = {
      module Id = ReventlessSpec.Id.StringPure
      let name = name ++ "References"
      @decco
      type state = Counter_Operations.referencesState

      let subIdConfig = None
      let config = ReventlessSpec.ReadModel_Spec.config()
    }

    module ReferencesDb = QueryDb.Make(
      Config,
      ReferencesSpec,
      QueryDbStorage,
      QueryDb.Adapter.NoResolvers(Config),
    )

    module CountsSpec = {
      module Id = ReventlessSpec.Id.StringPure
      let name = name ++ "Counts"
      @decco
      type state = Counter_Callback.countsState

      let subIdConfig = None
      let config = ReventlessSpec.ReadModel_Spec.config()
    }
    module CountsDb = QueryDb.Make(
      Config,
      CountsSpec,
      QueryDbStorage,
      QueryDb.Adapter.NoResolvers(Config),
    )

    let referencesDb = ReferencesDb.make(~ttl?, ~opts)
    let countsDb = CountsDb.make(~ttl?, ~opts)

    let handler =
      countsDb
      ->Component.operations
      ->Pulumi.Output.apply(({count}) => {
        module Callback = Counter_Callback.Make({
          let name = name
          let countsDbCount = count
          let counterEventsHandler = counterEventsHandler
        })

        Handler.make(
          ~name,
          ~referencesName=ReferencesSpec.name,
          ~referencesDb=referencesDb->Component.extractOutputs,
          ~countsName=CountsSpec.name,
          ~countsDb=countsDb->Component.extractOutputs,
          ~counterHandler=Callback.counterHandler,
          ~opts=opts2,
        )
      })

    self->Component.setOperations(
      (referencesDb->Component.operations, handler)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply((({saveBatch}, handler)) => {
        module Operations = Counter_Operations.Make({
          let ttl = ttl
          let saveBatch = saveBatch
        })
        {
          Counter.count: Operations.count,
          addToCounterTarget: handler.addToCounterTarget,
        }
      }),
    )

    self->Component.setOutputs({
      Counter.referencesDb: referencesDb->Component.extractOutputs,
      countsDb: countsDb->Component.extractOutputs,
    })
  }

  let oneWeek = 60 * 60 * 24 * 7 //604800 sec

  let make = (~name, ~counterEventsHandler, ~ttl=oneWeek, ~opts=?) =>
    Component.make(
      ~componentType=Counter.componentType->ComponentType.toString,
      ~name=name->ComponentType.name(Counter.componentType),
      ~construct=construct(~counterEventsHandler, ~ttl=Some(ttl), ...),
      ~opts,
    )
}
