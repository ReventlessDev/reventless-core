open ReventlessSpec.Adapter

let componentType = ComponentType.DcbEventLog

type outputs = {resources: array<resource>, eventTopic: EventTopic.outputs}

type t
type component<'operations> = Component.t<t, outputs, 'operations>

type sequencedEvent<'event> = {
  position: DcbTag.sequencePosition,
  event: 'event,
  tags: array<DcbTag.tag>,
}

type readResult<'event> = {
  events: array<sequencedEvent<'event>>,
  headPosition?: DcbTag.sequencePosition,
}

type read<'event> = (
  ~query: DcbTag.query,
  ~after: DcbTag.sequencePosition=?,
) => promise<readResult<'event>>

type append<'event> = (
  array<'event>,
  ~condition: DcbTag.appendCondition=?,
) => promise<result<DcbTag.sequencePosition, string>>

type operations<'event> = {
  read: read<'event>,
  append: append<'event>,
}

module type Spec = {
  let name: string

  @schema
  type event
}

module type T = {
  module Spec: Spec

  type component = component<operations<Spec.event>>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
