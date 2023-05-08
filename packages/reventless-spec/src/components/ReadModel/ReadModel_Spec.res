type subId =
  | Field(string)
  | Argument(string)
  | NoSubId

type resolvedField =
  | Single(string)
  | Multi(string)

type resolveIdSourceConfig = {
  idField: string,
  subId: subId,
  resolvedField: resolvedField,
}

type targetIdField =
  | Index(string)
  | IndexWithId(string, string)
  | Id

type resolveIdTargetConfig = {
  pluginName?: string,
  tableName: string,
  idField: targetIdField,
  subIdField?: string,
}

type resolveConfig<'source, 'target> = {
  source: 'source,
  target: 'target,
}

@ocaml.doc(" resolve single id field ")
type resolveIdConfig = resolveConfig<resolveIdSourceConfig, resolveIdTargetConfig>

type resolveIdsSourceConfig = {
  idsField: string,
  resolvedField: string,
}

type resolveIdsTargetConfig = {
  pluginName?: string,
  tableName: string,
  subIdField?: string,
}

@ocaml.doc(" resolve id array field ")
type resolveIdsConfig = resolveConfig<resolveIdsSourceConfig, resolveIdsTargetConfig>

type authorization = {
  tableName: string,
  group: string,
}

type indexConfig = {
  index: string,
  _type: string,
  idField?: string,
  subIdField?: string,
  projectionType: [#KEYS_ONLY | #ALL | #INCLUDE(array<string>)],
  authorization?: authorization,
}

type subIdConfig<'state> = {
  subIdField: string,
  getSubId: 'state => string,
}

type config = {
  resolveId: array<resolveIdConfig>,
  resolveIds: array<resolveIdsConfig>,
  indexes: array<indexConfig>,
}

let config = (~resolveId=[], ~resolveIds=[], ~indexes=[], ()) => {
  resolveId,
  resolveIds,
  indexes,
}

module type T = {
  module Id: Id.T

  let name: string

  @decco
  type state

  let config: config
  let subIdConfig: option<subIdConfig<state>>
}
