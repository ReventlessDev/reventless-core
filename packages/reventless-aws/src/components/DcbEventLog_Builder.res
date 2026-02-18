module Make = (Spec: ReventlessSpec.DcbEventLog_Spec.T): (
  Reventless.DcbEventLog.T with module Spec = Spec
) => Reventless.DcbEventLog_Builder.Make(
  Spec,
  DcbEventLogStorage.DynamoDb,
  EventTopicPublisher.DynamoDbStream,
)
