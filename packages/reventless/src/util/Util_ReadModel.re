let queryDbStorageResource = (resources, readModelName) =>
  resources->Util_EventLog.getStorageResource(
    readModelName->ComponentType.name(ComponentType.ReadModel),
  );
