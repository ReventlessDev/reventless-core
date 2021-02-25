module Make =
       (
         Config: Config.T,
         Spec: Reventless.Aggregate.Spec,
         Behaviour: Reventless.Behaviour.T with module Spec := Spec,
       )
       : Reventless.Aggregate.T =>
  Reventless.Aggregate.Make(
    Config,
    Spec,
    Behaviour,
    CommandGeneratorResolvers.AppSync,
    CommandTopicConnector.SQS,
    EventLogStorage.DynamoDb,
    EventTopicPublisher.SNS,
  );
