/** resolve single id field */
type resolveIdConfig = {
  idField: string,
  sortField: option(string), // TODO: make optional field
  field: string,
  pluginName: option(string), // TODO: make optional field
  tableName: string,
  index: option(string), // TODO: make optional field
  targetIdField: option(string), // TODO: make optional field
  targetSortField: option(string) // TODO: make optional field
};

/** resolve id list field */
type resolveIdsConfig = {
  idsField: string,
  field: string,
  pluginName: option(string), // TODO: make optional field
  tableName: string,
  sortField: option(string) // TODO: make optional field
};

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
