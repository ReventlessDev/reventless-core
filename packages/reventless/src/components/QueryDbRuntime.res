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
