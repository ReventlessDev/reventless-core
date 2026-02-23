@schema
type storageError =
  | NotSavedToStorage(string)
  | NotLoadedFromStorage(string)
  | NotCountedOnStorage(string)
  | NotDeletedFromStorage(string)
  | BatchNotFullyWrittenToStorage(string)
  | StaleState
  | MissingSubIdConfig

type rec resolversResourcesMaker = dict<outputs> => array<Adapter.resource>
and outputs = {
  resources: array<Adapter.resource>,
  resolversMaker: resolversResourcesMaker,
}
type allOutputs = dict<outputs>
