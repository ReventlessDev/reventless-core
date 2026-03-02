let componentType = ComponentType.QueryDb

type outputs = ReventlessInfra.QueryDb.outputs
type allOutputs = ReventlessInfra.QueryDb.allOutputs
type resolversResourcesMaker = ReventlessInfra.QueryDb.resolversResourcesMaker

type t

type saveMode =
  | Init
  | Overwrite
  | Any

type load<'id, 'state> = 'id => promise<result<array<'state>, ReventlessInfra.QueryDb.storageError>>
type loadStream<'id, 'state> = 'id => Stream.t<'state, ReventlessInfra.QueryDb.storageError, unit>
type save<'id, 'state> = (
  'id,
  'state,
  saveMode,
  option<int>,
) => promise<result<unit, ReventlessInfra.QueryDb.storageError>>
type saveBatch<'id, 'state> = array<('id, 'state, option<int>)> => promise<
  result<unit, ReventlessInfra.QueryDb.storageError>,
>
type count<'id> = ('id, string, int) => promise<result<int, ReventlessInfra.QueryDb.storageError>>
type delete<'id> = (
  'id,
  option<(string, string)>,
) => promise<result<unit, ReventlessInfra.QueryDb.storageError>>
type deleteBatch<'id> = array<('id, option<(string, string)>)> => promise<
  result<unit, ReventlessInfra.QueryDb.storageError>,
>

type operations<'id, 'state> = {
  load: load<'id, 'state>,
  loadStream: loadStream<'id, 'state>,
  save: save<'id, 'state>,
  saveBatch: saveBatch<'id, 'state>,
  count: count<'id>,
  delete: delete<'id>,
  deleteBatch: deleteBatch<'id>,
}

module type T = {
  module Spec: Reventless.ReadModel.Spec

  type api
  type role
  type operations = operations<Spec.Id.t, Spec.state>
  type component = Component.t<t, outputs, operations>

  let make: (
    ~api: api,
    ~apiRole: role,
    ~ttl: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let allResolversMakers = allQueryDbs =>
  allQueryDbs
  ->Dict.valuesToArray
  ->Array.map((queryDb: outputs) => queryDb.resolversMaker)

let storageErrorToString: ReventlessInfra.QueryDb.storageError => string = err =>
  switch err {
  | NotSavedToStorage(s) => `NotSavedToStorage(${s})`
  | NotLoadedFromStorage(s) => `NotLoadedFromStorage(${s})`
  | NotCountedOnStorage(s) => `NotCountedOnStorage(${s})`
  | NotDeletedFromStorage(s) => `NotDeletedFromStorage(${s})`
  | BatchNotFullyWrittenToStorage(s) => `BatchNotFullyWrittenToStorage(${s})`
  | StaleState => `StaleState`
  | MissingSubIdConfig => `MissingSubIdConfig`
  }
