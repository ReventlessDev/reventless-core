type rec resolversResourcesMaker = Js.Dict.t<outputs> => array<Adapter.resource>
and outputs = {resources: array<Adapter.resource>, resolversMaker: resolversResourcesMaker}
type allOutputs = Js.Dict.t<outputs>

type saveMode =
  | Init
  | Overwrite
  | Any

@decco
type storageError =
  | NotSavedToStorage(string)
  | NotLoadedFromStorage(string)
  | NotCountedOnStorage(string)
  | NotDeletedFromStorage(string)
  | BatchNotFullyWrittenToStorage(string)
  | StaleState
  | MissingSubIdConfig

type load<'id, 'state> = (. 'id) => Js.Promise.t<Belt.Result.t<array<'state>, storageError>>
type save<'id, 'state> = (
  . 'id,
  'state,
  saveMode,
  option<int>,
) => Js.Promise.t<Belt.Result.t<unit, storageError>>
type saveBatch<'id, 'state> = (
  . array<('id, 'state, option<int>)>,
) => Js.Promise.t<Belt.Result.t<unit, storageError>>
type count<'id> = (. 'id, string, int) => Js.Promise.t<Belt.Result.t<int, storageError>>
type delete<'id> = (
  . 'id,
  option<(string, string)>,
) => Js.Promise.t<Belt.Result.t<unit, storageError>>
type deleteBatch<'id> = (
  . array<('id, option<(string, string)>)>,
) => Js.Promise.t<Belt.Result.t<unit, storageError>>

module type T = {
  module Spec: ReadModel_Spec.T
  type t

  type load = load<Spec.Id.t, Spec.state>
  type save = save<Spec.Id.t, Spec.state>
  type saveBatch = saveBatch<Spec.Id.t, Spec.state>
  type count = count<Spec.Id.t>
  type delete = delete<Spec.Id.t>
  type deleteBatch = deleteBatch<Spec.Id.t>

  let make: (
    ~ttl: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
    unit,
  ) => Component.t<t, outputs>

  let load: Component.t<t, outputs> => load
  let save: Component.t<t, outputs> => save
  let saveBatch: Component.t<t, outputs> => saveBatch
  let count: Component.t<t, outputs> => count
  let delete: Component.t<t, outputs> => delete
  let deleteBatch: Component.t<t, outputs> => deleteBatch

  let outputs: Component.t<t, outputs> => outputs
}
