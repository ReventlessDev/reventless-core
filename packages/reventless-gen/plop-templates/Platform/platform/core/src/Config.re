open Reventless;

let pluginName = "Core";

[@bs.val] [@bs.module "../package.json"] external version: string = "version";

type api = Pulumi.Output.t(PulumiAws.AppSync.GraphQLApi.t);
type role = Pulumi.Output.t(PulumiAws.IAM.Role.t);
type userPool = Pulumi.Output.t(PulumiAws.Cognito.UserPool.t);

let apiStack =
  Pulumi.Config.(make(Some("api"))->get("stack"))
  ->Belt.Option.getExn
  ->Pulumi.StackReference.make;

let get = outputName =>
  apiStack->Pulumi.StackReference.getOutput(outputName)->Belt.Option.getExn;

let userPoolId: Pulumi.Output.t(string) = get("userPoolId");

let api: api =
  PulumiAws.AppSync.GraphQLApi.(
    make(
      ~name="CoreApi",
      ~userPoolId,
      ~schema=CoreApi.graphQLSchema->Pulumi.Input.wrap,
      (),
    )
  )
  ->Pulumi.Output.make;

let apiRole: role = get("apiRole");

module Scheduler =
  Scheduler.Make(ReventlessAws.ScheduledPublisher.CloudWatchEvents);
let scheduler = Scheduler.make();
