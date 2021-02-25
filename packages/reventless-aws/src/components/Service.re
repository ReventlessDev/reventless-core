module Make =
       (
         Config: Config.T,
         Spec: Reventless.Aggregate.Spec,
         Behaviour: Reventless.Behaviour.T with module Spec := Spec,
         View: Reventless.View.T with module Spec := Spec,
       )
       : Reventless.Service.T =>
  Reventless.Service.Make(
    Config,
    Spec,
    Behaviour,
    View,
    CommandGeneratorResolvers.AppSync,
    CommandTopicConnector.SQS,
    EventLogStorage.DynamoDb,
    EventTopicPublisher.SNS,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
  );
