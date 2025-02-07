open ReventlessSpec.Adapter
open ReventlessSpec.QueryDb

let componentType = ComponentType.QueryDb

type rec resolversResourcesMaker = Js.Dict.t<outputs> => array<resource>
and outputs = {
  resources: array<resource>,
  resolversMaker: resolversResourcesMaker,
}
type allOutputs = Js.Dict.t<outputs>

type t
type component = Component.t<t, outputs, unit>

let allResolversMakers = allQueryDbs =>
  allQueryDbs
  ->Js.Dict.values
  ->Belt.Array.map((queryDb: outputs) => queryDb.resolversMaker)

type primitives<'id, 'state> = {
  load: load<'id, 'state>,
  save: save<'id, 'state>,
  saveBatch: saveBatch<'id, 'state>,
  count: count<'id>,
  delete: delete<'id>,
  deleteBatch: deleteBatch<'id>,
}

module type T = {
  module Spec: ReventlessSpec.ReadModel_Spec.T

  type primitives = primitives<Spec.Id.t, Spec.state>
  let primitives: component => Pulumi.Output.t<primitives>

  let make: (~ttl: int=?, ~opts: Pulumi.ComponentResource.options=?) => component
}

module Adapter = {
  open ReventlessSpec.ReadModel_Spec

  type primitives = primitives<string, Js.Json.t>

  type storage = {
    resources: array<resource>,
    dataSourceName: Pulumi.Output.t<string>, // TODO create in API
    primitives: Pulumi.Output.t<primitives>,
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

  type queryEngineMaker = Js.Dict.t<outputs> => ReventlessSpec.QueryEngine.t

  module type QueryEngineAdapter = {
    let make: queryEngineMaker
  }

  type resolvers = {
    resources: array<resource>,
    resourcesMaker: resolversResourcesMaker,
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
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Storage: Adapter.Storage with type api = Config.api and type role = Config.role,
  Resolvers: Adapter.Resolvers with type api = Config.api and type role = Config.role,
): (T with module Spec = Spec) => {
  module Spec = Spec

  type api = Config.api
  type role = Config.role

  type primitives = primitives<Spec.Id.t, Spec.state>

  type constructed
  type construct = (component, string, api, role) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
    ~api: api,
    ~apiRole: role,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send
  external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setPrimitives: (component, Pulumi.Output.t<primitives>) => unit = "primitives"
  @get
  external primitives: component => Pulumi.Output.t<primitives> = "primitives"

  let construct = (~ttl=?, self, name, api, apiRole) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let subIdField = Spec.subIdConfig->Belt.Option.map(config => config.subIdField)
    let storageName = name->ComponentType.name(componentType)

    module Runtime = QueryDb_Runtime.Make(Spec)

    let storage = Storage.make(
      ~name=storageName,
      ~indexes=Spec.config.indexes,
      ~subIdField?,
      ~ttl?,
      ~api,
      ~apiRole,
      ~opts,
    )

    self->setPrimitives(
      storage.primitives->Pulumi.Output.apply(({
        load,
        save,
        saveBatch,
        count,
        delete,
        deleteBatch,
      }) => {
        load: Runtime.loadStates(load),
        save: Runtime.saveState(save),
        saveBatch: Runtime.saveStates(saveBatch),
        count: Runtime.countFn(count),
        delete: Runtime.deleteState(delete),
        deleteBatch: Runtime.deleteStates(deleteBatch),
      }),
    )

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

    self->setOutputs({
      resources: storage.resources->Belt.Array.concat(resolvers.resources),
      resolversMaker: resolvers.resourcesMaker,
    })
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
