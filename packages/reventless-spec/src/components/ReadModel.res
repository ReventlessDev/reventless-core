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

/** resolve single id field */
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

/** resolve id array field */
type idsResolverConfig = resolveConfig<idsResolverSourceConfig, idsResolverTargetConfig>

type authorization = {
  tableName: string,
  group: string,
}

type projectionType = KEYS_ONLY | ALL | INCLUDE(array<string>)

type indexConfig = {
  index: string,
  type_: string,
  idField?: string,
  subIdField?: string,
  projectionType: projectionType,
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

let config = (~idResolvers=[], ~idsResolvers=[], ~indexes=[]) => {
  idResolvers,
  idsResolvers,
  indexes,
}

module type Spec = {
  module Id: Id.T

  let name: string

  @schema
  type state

  let config: config
  let subIdConfig: option<subIdConfig<state>>
}

type outputs = {
  name: string,
  queryDb: QueryDb.outputs,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  sourceNames: array<string>,
}
type operations = {enqueueEvent: EventCollector.enqueueEvent}

module type T = {
  module Spec: Spec
  type api
  type role
  type component
  let make: (
    ~api: api,
    ~apiRole: role,
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
  let finish: unit => unit
}
