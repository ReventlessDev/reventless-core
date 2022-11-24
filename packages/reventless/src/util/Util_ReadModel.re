let queryDbStorageResources = (resources, readModelName) =>
  resources->Util_QueryDbRuntime.getLocalStorageResources(readModelName);

let allQueryDbs = allReadModels =>
  Js.Dict.map((. readModel) => readModel##queryDb, allReadModels);
