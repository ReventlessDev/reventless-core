/** resolve single id field */
type resolveIdConfig = {
  fieldName: string,
  tableName: string,
  idFieldName: string,
};

/** resolve id list field */
type resolveIdsConfig = {
  fieldName: string,
  tableName: string,
  idsFieldName: string,
};

type index = {
  index: string,
  _type: string,
  sortField: option(string),
  deletable: bool, // TODO: not used anymore
  projectionType: [ | `KEYS_ONLY | `ALL | `INCLUDE(array(string))],
  authorization: option(string),
};

type sortConfig('state) = {
  sortField: string,
  getSortKey: 'state => string,
};

[@decco]
type action('state) =
  | /** Create new View state */
    Create('state)
  | /** Update View state */
    Update('state)
  | /** Delete View */
    Delete('state)
  | /** Keep View unchanged */
    Unchanged('state);
[@decco]
type actions('state) = list(action('state));

type init('state, 'event) = (. 'event, Message.context) => list('state);
type apply('state, 'event) =
  (. 'state, 'event, Message.context) => list(action('state));
type applyMulti('state, 'event) =
  (. list('state), 'event, Message.context) => list(action('state));

module type T = {
  type event;

  [@decco]
  type state;

  let name: option(string);

  let resolveIdConfigs: list(resolveIdConfig);
  let resolveIdsConfigs: list(resolveIdsConfig);

  let sortConfig: option(sortConfig(state));

  let indexes: list(index);

  let init: init(state, event);
  let apply: apply(state, event);
  let applyMulti: applyMulti(state, event);
};