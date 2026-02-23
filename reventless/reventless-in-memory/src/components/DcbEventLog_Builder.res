// In-memory DcbEventLog builder.

module Make = (Bus: InMemory_Bus.T) => {
  module EventTopicPublisher = EventTopicPublisher_InMemory.Make(Bus)

  module Make = (
    Spec: ReventlessSpec.DcbEventLog.Spec,
  ): (Reventless.DcbEventLog.T with module Spec = Spec) =>
    Reventless.DcbEventLog_Builder.Make(Spec, DcbEventLogStorage_InMemory, EventTopicPublisher)
}
