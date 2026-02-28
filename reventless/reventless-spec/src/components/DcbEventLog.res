module type Spec = {
  @schema
  type event
}

module type T = {
  module Spec: Spec
  type component
  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}

type outputs = {resources: array<Adapter.resource>, eventTopic: EventTopic.outputs}

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

type readStream<'event> = (
  ~query: DcbTag.query,
  ~after: DcbTag.sequencePosition=?,
) => Stream.t<sequencedEvent<'event>, string, unit>

type operations<'event> = {
  read: read<'event>,
  append: append<'event>,
  readStream: readStream<'event>,
}
