let componentType = ComponentType.Counter

type outputs = {
  "referencesDb": ReventlessSpec.QueryDb.outputs,
  "countsDb": ReventlessSpec.QueryDb.outputs,
}

type t
type component = ReventlessSpec.Component.t<t, outputs>

type action =
  | Count(Counter_Runtime.countItem)
  | AddToCounterTarget(Counter_Runtime.counterTargetRef)

module Source = {
  module Id = ReventlessSpec.Id.String
  let name = ComponentType.Counter->ComponentType.toName
  @decco
  type event = Counter_Runtime.counterEvent
}

type count = array<Counter_Runtime.countItem> => Js.Promise.t<unit>
type addToCounterTarget = Counter_Runtime.counterTargetRef => Js.Promise.t<unit>

type counterEventsHandler = array<Js.Json.t> => Js.Promise.t<unit>

module type T = {
  let make: (
    ~name: string,
    ~counterEventsHandler: counterEventsHandler,
    ~ttl: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component

  let count: component => count
  let addToCounterTarget: component => addToCounterTarget
}

module Adapter = {
  type handler = {addToCounterTarget: addToCounterTarget}
  type handlerMaker = (
    ~name: string,
    ~referencesName: string,
    ~referencesDb: ReventlessSpec.QueryDb.outputs,
    ~countsName: string,
    ~countsDb: ReventlessSpec.QueryDb.outputs,
    ~counterHandler: Counter_Runtime.counterHandler,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => handler

  module type Handler = {
    let make: handlerMaker
  }
}

module Make = (
  Config: Config.T,
  QueryDbStorage: QueryDb.Adapter.Storage with type api = Config.api and type role = Config.role,
  Handler: Adapter.Handler,
): T => {
  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component = "default"

  @obj
  external makeOutputs: (
    ~referencesDb: ReventlessSpec.QueryDb.outputs,
    ~countsDb: ReventlessSpec.QueryDb.outputs,
  ) => outputs = ""

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set external setCount: (component, count) => unit = "count"
  @get external count: component => count = "count"

  @set
  external setAddToCounterTarget: (component, addToCounterTarget) => unit = "addToCounterTarget"
  @get
  external addToCounterTarget: component => addToCounterTarget = "addToCounterTarget"

  let construct = (~counterEventsHandler: counterEventsHandler, ~ttl: option<int>, self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let opts2 = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    module ReferencesSpec = {
      module Id = ReventlessSpec.Id.StringPure
      let name = name ++ "References"
      @decco
      type state = Counter_Runtime.referencesState

      let subIdConfig = None
      let config = ReventlessSpec.ReadModel.Spec.config()
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
      type state = Counter_Runtime.countsState

      let subIdConfig = None
      let config = ReventlessSpec.ReadModel.Spec.config()
    }
    module CountsDb = QueryDb.Make(
      Config,
      CountsSpec,
      QueryDbStorage,
      QueryDb.Adapter.NoResolvers(Config),
    )

    let referencesDb = ReferencesDb.make(~ttl?, ~opts)
    let countsDb = CountsDb.make(~ttl?, ~opts)

    let handler = Handler.make(
      ~name,
      ~referencesName=ReferencesSpec.name,
      ~referencesDb=referencesDb->Component.extractOutputs,
      ~countsName=CountsSpec.name,
      ~countsDb=countsDb->Component.extractOutputs,
      ~counterHandler=Counter_Runtime.counterHandler(
        name,
        countsDb->CountsDb.count,
        counterEventsHandler,
      ),
      ~opts=opts2,
    )

    self->setCount(countItems =>
      Counter_Runtime.count(ttl)(referencesDb->ReferencesDb.saveBatch, countItems)
    )
    self->setAddToCounterTarget(handler.addToCounterTarget)

    self->setOutputs(
      makeOutputs(
        ~referencesDb=referencesDb->ReferencesDb.outputs,
        ~countsDb=countsDb->CountsDb.outputs,
      ),
    )
  }

  let oneWeek = 60 * 60 * 24 * 7 //604800 sec

  let make = (~name, ~counterEventsHandler, ~ttl=oneWeek, ~opts=?) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=name->ComponentType.name(componentType),
      ~construct=construct(~counterEventsHandler, ~ttl=Some(ttl), ...),
      ~opts,
    )
}
