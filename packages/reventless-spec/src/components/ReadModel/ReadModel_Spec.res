type subId =
  | Field(string)
  | Argument(string)
  | NoSubId

type resolvedField =
  | Single(string)
  | Multi(string)

type idResolverSourceConfig = {
  idField: string,
  subId: subId,
  resolvedField: resolvedField,
}

type targetIdField =
  | Index(string)
  | IndexWithId(string, string)
  | Id

type idResolverTargetConfig = {
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
type idResolverConfig = resolveConfig<idResolverSourceConfig, idResolverTargetConfig>

type idsResolverSourceConfig = {
  idsField: string,
  resolvedField: string,
}

type idsResolverTargetConfig = {
  pluginName?: string,
  tableName: string,
  subIdField?: string,
}

@ocaml.doc(" resolve id array field ")
type idsResolverConfig = resolveConfig<idsResolverSourceConfig, idsResolverTargetConfig>

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
  idResolvers: array<idResolverConfig>,
  idsResolvers: array<idsResolverConfig>,
  indexes: array<indexConfig>,
}

let config = (~idResolvers=[], ~idsResolvers=[], ~indexes=[], ()) => {
  idResolvers,
  idsResolvers,
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
