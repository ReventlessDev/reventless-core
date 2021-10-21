[@decco]
type name = string;
[@decco]
type version = string;

[@decco]
type extensionPointDefinition = {
  name: string,
  commandTopic: string,
  eventTopic: string,
};

[@decco]
type extensionDefinition = {
  name: string,
  extensionPointName: string,
};

[@decco]
type pluginDefinition = {
  id: string,
  name,
  version,
  extensionPoints: array(extensionPointDefinition),
  extensions: array(extensionDefinition),
  eventCollector: string,
};

[@decco]
type schema = string;
[@decco]
type typeSchema = {
  name: string,
  schema,
};
[@decco]
type querySchema = {
  schema,
  roles: array(string),
};

[@decco]
type apiFragmentDescription = {
  name,
  typeSchemas: array(typeSchema),
  queriesSchema: array(querySchema),
  mutationsSchema: array(querySchema),
};
