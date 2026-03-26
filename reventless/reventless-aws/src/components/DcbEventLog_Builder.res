// AWS DcbEventLog builder — no longer used directly.
// The DcbEventLog is created internally by Dcb_Builder via ReventlessCore.DcbEventLog_Builder.
// This module is retained for potential future use.

include ReventlessCore.DcbEventLog_Builder.Make(
  DcbEventLogStorage.DynamoDb,
  EventTopicPublisher.DynamoDbStream,
)
