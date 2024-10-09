let queryDbStorageResources = (queryDbs, readModelName) =>
  queryDbs->Util_QueryDbRuntime.getLocalStorageResources(readModelName)
