module Make =
       (
         Config:
           Reventless.Config.T with
             type api = Pulumi.Output.t(PulumiAws.AppSync.GraphQLApi.t) and
             type role = Pulumi.Output.t(PulumiAws.IAM.Role.t),
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
