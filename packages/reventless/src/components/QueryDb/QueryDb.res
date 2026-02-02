let componentType = ComponentType.QueryDb

type rec resolversResourcesMaker = dict<outputs> => array<ReventlessSpec.Adapter.resource>
and outputs = {
  resources: array<ReventlessSpec.Adapter.resource>,
  resolversMaker: resolversResourcesMaker,
}
type allOutputs = dict<outputs>

type t

type saveMode =
  | Init
  | Overwrite
  | Any

type load<'id, 'state> = 'id => promise<result<array<'state>, ReventlessSpec.QueryDb.storageError>>
type save<'id, 'state> = (
  'id,
  'state,
  saveMode,
  option<int>,
) => promise<result<unit, ReventlessSpec.QueryDb.storageError>>
type saveBatch<'id, 'state> = array<('id, 'state, option<int>)> => promise<
  result<unit, ReventlessSpec.QueryDb.storageError>,
>
type count<'id> = ('id, string, int) => promise<result<int, ReventlessSpec.QueryDb.storageError>>
type delete<'id> = (
  'id,
  option<(string, string)>,
) => promise<result<unit, ReventlessSpec.QueryDb.storageError>>
type deleteBatch<'id> = array<('id, option<(string, string)>)> => promise<
  result<unit, ReventlessSpec.QueryDb.storageError>,
>

type operations<'id, 'state> = {
  load: load<'id, 'state>,
  save: save<'id, 'state>,
  saveBatch: saveBatch<'id, 'state>,
  count: count<'id>,
  delete: delete<'id>,
  deleteBatch: deleteBatch<'id>,
}

module type T = {
  module Spec: ReventlessSpec.ReadModel_Spec.T

  type operations = operations<Spec.Id.t, Spec.state>
  type component = Component.t<t, outputs, operations>

  let make: (~ttl: int=?, ~opts: Pulumi.ComponentResource.options=?) => component
}

let allResolversMakers = allQueryDbs =>
  allQueryDbs
  ->Dict.valuesToArray
  ->Array.map((queryDb: outputs) => queryDb.resolversMaker)

let storageErrorToString: ReventlessSpec.QueryDb.storageError => string = err =>
  switch err {
  | NotSavedToStorage(s) => `NotSavedToStorage(${s})`
  | NotLoadedFromStorage(s) => `NotLoadedFromStorage(${s})`
  | NotCountedOnStorage(s) => `NotCountedOnStorage(${s})`
  | NotDeletedFromStorage(s) => `NotDeletedFromStorage(${s})`
  | BatchNotFullyWrittenToStorage(s) => `BatchNotFullyWrittenToStorage(${s})`
  | StaleState => `StaleState`
  | MissingSubIdConfig => `MissingSubIdConfig`
  }
