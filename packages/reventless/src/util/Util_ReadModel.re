let queryDbStorageResources = (queryDbs, readModelName) =>
  queryDbs->Util_QueryDbRuntime.getLocalStorageResources(readModelName);

let allQueryDbs = allReadModels =>
  Js.Dict.map((. readModel) => readModel##queryDb, allReadModels);
