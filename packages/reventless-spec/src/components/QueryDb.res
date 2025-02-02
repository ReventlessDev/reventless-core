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

type load<'id, 'state> = 'id => Js.Promise.t<Belt.Result.t<array<'state>, storageError>>
type save<'id, 'state> = (
  'id,
  'state,
  saveMode,
  option<int>,
) => Js.Promise.t<Belt.Result.t<unit, storageError>>
type saveBatch<'id, 'state> = array<('id, 'state, option<int>)> => Js.Promise.t<
  Belt.Result.t<unit, storageError>,
>
type count<'id> = ('id, string, int) => Js.Promise.t<Belt.Result.t<int, storageError>>
type delete<'id> = (
  'id,
  option<(string, string)>,
) => Js.Promise.t<Belt.Result.t<unit, storageError>>
type deleteBatch<'id> = array<('id, option<(string, string)>)> => Js.Promise.t<
  Belt.Result.t<unit, storageError>,
>
