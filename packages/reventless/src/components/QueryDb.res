open ReventlessSpec.Adapter

let componentType = ComponentType.QueryDb

let allResolversMakers = allQueryDbs =>
  allQueryDbs
  ->Js.Dict.values
  ->Belt.Array.map((queryDb: ReventlessSpec.QueryDb.outputs) => queryDb.resolversMaker)

module type AggregateSpec = {
  module Id: ReventlessSpec.Id.T
  let name: string
}

module Adapter = {
  open ReventlessSpec.ReadModel.Spec

  type storage = {
    resources: array<resource>,
    dataSourceName: Pulumi.Output.t<string>, // TODO create in API
    load: ReventlessSpec.QueryDb.load<string, Js.Json.t>,
    save: ReventlessSpec.QueryDb.save<string, Js.Json.t>,
    saveBatch: ReventlessSpec.QueryDb.saveBatch<string, Js.Json.t>,
    count: ReventlessSpec.QueryDb.count<string>,
    delete: ReventlessSpec.QueryDb.delete<string>,
    deleteBatch: ReventlessSpec.QueryDb.deleteBatch<string>,
  }
  type storageMaker<'api, 'role> = (
    ~name: string,
    ~indexes: array<indexConfig>,
    ~subIdField: string=?,
    ~ttl: int=?,
    ~api: 'api,
    ~apiRole: 'role,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => storage

  module type Storage = {
    type api
    type role

    let make: storageMaker<api, role>
  }

  type queryEngineMaker = Js.Dict.t<ReventlessSpec.QueryDb.outputs> => ReventlessSpec.QueryEngine.t

  module type QueryEngineAdapter = {
    let make: queryEngineMaker
  }

  type resolvers = {
    resources: array<resource>,
    resourcesMaker: ReventlessSpec.QueryDb.resolversResourcesMaker,
  }
  type resolversMaker<'api, 'role> = (
    ~name: string,
    ~api: 'api,
    ~apiRole: 'role,
    ~dataSourceName: Pulumi.Output.t<string>,
    ~indexes: array<indexConfig>,
    ~subIdField: option<string>,
    ~idResolverConfigs: array<idResolverConfig>,
    ~idsResolverConfigs: array<idsResolverConfig>,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => resolvers

  module type Resolvers = {
    type api
    type role

    let make: resolversMaker<api, role>
  }

  module NoResolvers = (Config: Config.T) => {
    type api = Config.api
    type role = Config.role

    let make: resolversMaker<api, role> = (
      ~name as _: string,
      ~api as _: api,
      ~apiRole as _: role,
      ~dataSourceName as _,
      ~indexes as _: array<indexConfig>,
      ~subIdField as _,
      ~idResolverConfigs as _: array<idResolverConfig>,
      ~idsResolverConfigs as _: array<idsResolverConfig>,
      ~opts as _,
    ) => {
      resources: [],
      resourcesMaker: _ => [],
    }
  }
}

module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.ReadModel.Spec.T,
  Storage: Adapter.Storage with type api = Config.api and type role = Config.role,
  Resolvers: Adapter.Resolvers with type api = Config.api and type role = Config.role,
): (ReventlessSpec.QueryDb.T with module Spec = Spec) => {
  module Spec = Spec
  type t

  type api = Config.api
  type role = Config.role

  type load = ReventlessSpec.QueryDb.load<Spec.Id.t, Spec.state>
  type save = ReventlessSpec.QueryDb.save<Spec.Id.t, Spec.state>
  type saveBatch = ReventlessSpec.QueryDb.saveBatch<Spec.Id.t, Spec.state>
  type count = ReventlessSpec.QueryDb.count<Spec.Id.t>
  type delete = ReventlessSpec.QueryDb.delete<Spec.Id.t>
  type deleteBatch = ReventlessSpec.QueryDb.deleteBatch<Spec.Id.t>

  type constructed
  type construct = (
    ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs>,
    string,
    api,
    role,
  ) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
    ~api: api,
    ~apiRole: role,
  ) => ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs> = "default"

  @obj
  external makeOutputs: (
    ~resources: array<resource>,
    ~resolversMaker: ReventlessSpec.QueryDb.resolversResourcesMaker,
  ) => ReventlessSpec.QueryDb.outputs = ""

  @send
  external registerOutputs: (
    ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs>,
    ReventlessSpec.QueryDb.outputs,
  ) => constructed = "registerOutputs"
  @send
  external setOutputs: (
    ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs>,
    ReventlessSpec.QueryDb.outputs,
  ) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setLoad: (ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs>, load) => unit =
    "load"
  @set
  external setSave: (ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs>, save) => unit =
    "save"
  @set
  external setSaveBatch: (
    ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs>,
    saveBatch,
  ) => unit = "saveBatch"
  @set
  external setCount: (
    ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs>,
    count,
  ) => unit = "count"
  @set
  external setDelete: (
    ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs>,
    delete,
  ) => unit = "delete"
  @set
  external setDeleteBatch: (
    ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs>,
    deleteBatch,
  ) => unit = "deleteBatch"

  @get external load: ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs> => load = "load"
  @get external save: ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs> => save = "save"
  @get
  external saveBatch: ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs> => saveBatch =
    "saveBatch"
  @get
  external count: ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs> => count = "count"
  @get
  external delete: ReventlessSpec.Component.t<t, ReventlessSpec.QueryDb.outputs> => delete =
    "delete"
  @get
  external deleteBatch: ReventlessSpec.Component.t<
    t,
    ReventlessSpec.QueryDb.outputs,
  > => deleteBatch = "deleteBatch"

  let decode = (id, item) =>
    switch Spec.state_decode(item) {
    | Ok(state) => [state]
    | Error(err) =>
      Js.log(
        `QueryDb: Error: Couldn't decode state for ${id->Spec.Id.toString}: ${err
          ->Js.Json.stringifyAny
          ->Belt.Option.getExn}`,
      )
      []
    }

  let loadFn = storage =>
    async id =>
      switch await storage.Adapter.load(id->Spec.Id.toString) {
      | result =>
        result->Belt.Result.map(states =>
          states->Belt.Array.map(state => decode(id, state))->Belt.Array.concatMany
        )
      }

  let saveFn = storage =>
    async (id, state, saveMode, ttl) =>
      switch state->Spec.state_encode->Js.Json.decodeObject {
      | Some(dict) =>
        dict->Js.Dict.set("id", Spec.Id.t_encode(id))
        let json = Js.Json.object_(dict)
        await storage.Adapter.save(id->Spec.Id.toString, json, saveMode, ttl)
      | None =>
        Js.log2("QueryDB.save: Error: Couldn't decodeObject:", state->Js.Json.stringifyAny)
        Belt.Result.Error(ReventlessSpec.QueryDb.NotSavedToStorage("Couldn't decodeObject"))
      }

  let saveBatchFn = storage =>
    async items => {
      let batch = items->Belt.Array.keepMap(((id, state, ttl)) =>
        switch state->Spec.state_encode->Js.Json.decodeObject {
        | Some(dict) =>
          dict->Js.Dict.set("id", Spec.Id.t_encode(id))
          let json = Js.Json.object_(dict)
          Some((id->Spec.Id.toString, json, ttl))
        | None =>
          Js.log2("QueryDB.saveBatch: Error: Couldn't decodeObject:", state->Js.Json.stringifyAny)
          None
        }
      )
      await storage.Adapter.saveBatch(batch)
    }

  let countFn = storage =>
    async (id, fieldName, inc) => await storage.Adapter.count(id->Spec.Id.toString, fieldName, inc)

  let deleteFn = storage =>
    async (id, subId) => await storage.Adapter.delete(id->Spec.Id.toString, subId)

  let deleteBatchFn = storage =>
    async ids => {
      let ids = ids->Belt.Array.map(((id, sort)) => (id->Spec.Id.toString, sort))
      await storage.Adapter.deleteBatch(ids)
    }

  let outputs: ReventlessSpec.Component.t<
    t,
    ReventlessSpec.QueryDb.outputs,
  > => ReventlessSpec.QueryDb.outputs = component => Component.extractOutputs(component)

  let construct = (~ttl=?, self, name, api, apiRole) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let subIdField = Spec.subIdConfig->Belt.Option.map(config => config.subIdField)
    let storageName = name->ComponentType.name(componentType)
    let storage = Storage.make(
      ~name=storageName,
      ~indexes=Spec.config.indexes,
      ~subIdField?,
      ~ttl?,
      ~api,
      ~apiRole,
      ~opts,
    )

    self->setLoad(storage->loadFn)
    self->setSave(storage->saveFn)
    self->setSaveBatch(storage->saveBatchFn)
    self->setCount(storage->countFn)
    self->setDelete(storage->deleteFn)
    self->setDeleteBatch(storage->deleteBatchFn)

    let resolvers = Resolvers.make(
      ~name,
      ~api,
      ~apiRole,
      ~dataSourceName=storage.dataSourceName,
      ~indexes=Spec.config.indexes,
      ~subIdField,
      ~idResolverConfigs=Spec.config.idResolvers,
      ~idsResolverConfigs=Spec.config.idsResolvers,
      ~opts,
    )

    self->setOutputs(
      makeOutputs(
        ~resources=storage.resources->Belt.Array.concat(resolvers.resources),
        ~resolversMaker=resolvers.resourcesMaker,
      ),
    )
  }

  let make = (~ttl=?, ~opts=?) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~ttl?, ...),
      ~opts,
      ~api=Config.api,
      ~apiRole=Config.apiRole,
    )
}
