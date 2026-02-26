module Make = (Spec: Reventless.DcbEventLog.Spec): (
  ReventlessCore.DcbEventLog.T with module Spec = Spec
) => ReventlessCore.DcbEventLog_Builder.Make(
  Spec,
  DcbEventLogStorage.DynamoDb,
  EventTopicPublisher.DynamoDbStream,
)
