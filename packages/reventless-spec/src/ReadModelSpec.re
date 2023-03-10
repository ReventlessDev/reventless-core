type subId =
  | Field(string)
  | Argument(string)
  | NoSubId;

type resolvedField =
  | Single(string)
  | Multi(string);

type resolveIdSourceConfig = {
  idField: string,
  subId,
  resolvedField,
};

type targetIdField =
  | Index(string)
  | IndexWithId(string, string)
  | Id;

type resolveIdTargetConfig = {
  pluginName: option(string), // TODO: make optional field
  tableName: string,
  idField: targetIdField,
  subIdField: option(string) // TODO: make optional field
};

type resolveConfig('source, 'target) = {
  source: 'source,
  target: 'target,
};

/** resolve single id field */
type resolveIdConfig =
  resolveConfig(resolveIdSourceConfig, resolveIdTargetConfig);

type resolveIdsSourceConfig = {
  idsField: string,
  resolvedField: string,
};

type resolveIdsTargetConfig = {
  pluginName: option(string), // TODO: make optional field
  tableName: string,
  subIdField: option(string) // TODO: make optional field
};

/** resolve id list field */
type resolveIdsConfig =
  resolveConfig(resolveIdsSourceConfig, resolveIdsTargetConfig);

type authorization = {
  tableName: string,
  group: string,
};

type index = {
  index: string,
  _type: string,
  idField: option(string), // TODO: make optional field
  subIdField: option(string), // TODO: make optional field
  projectionType: [ | `KEYS_ONLY | `ALL | `INCLUDE(array(string))],
  authorization: option(authorization),
};

type subIdConfig('state) = {
  subIdField: string,
  getSubId: 'state => string,
};

module type T = {
  module Id: Id.T;

  let name: string;

  [@decco]
  type state;

  let resolveIdConfigs: list(resolveIdConfig);
  let resolveIdsConfigs: list(resolveIdsConfig);

  let subIdConfig: option(subIdConfig(state));

  let indexes: list(index);
};
