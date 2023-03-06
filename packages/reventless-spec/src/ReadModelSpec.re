type resolveIdSourceConfig = {
  idField: string,
  sortField: option(string), // TODO: make optional field
  field: string,
};

type resolveIdTargetConfig = {
  pluginName: option(string), // TODO: make optional field
  tableName: string,
  index: option(string), // TODO: make optional field
  idField: option(string), // TODO: make optional field
  sortField: option(string), // TODO: make optional field
  unique: bool,
};

type resolveConfig('source, 'target) = {
  source: 'source,
  target: 'target,
};

/** resolve single id field */
type resolveIdConfig =
  resolveConfig(resolveIdSourceConfig, resolveIdTargetConfig);

type resolveIdsTargetConfig = {
  pluginName: option(string), // TODO: make optional field
  tableName: string,
};

type resolveIdsSourceConfig = {
  idsField: string,
  sortField: option(string), // TODO: make optional field
  field: string,
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
  sortField: option(string), // TODO: make optional field
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
