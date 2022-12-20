/** resolve single id field */
type resolveIdConfig = {
  idFieldName: string,
  fieldName: string,
  tableName: string,
  index: option(string),
};

/** resolve id list field */
type resolveIdsConfig = {
  idsFieldName: string,
  fieldName: string,
  tableName: string,
  sortField: option(string),
};

type authorization = {
  tableName: string,
  group: string,
};
type index = {
  index: string,
  _type: string,
  sortField: option(string),
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
