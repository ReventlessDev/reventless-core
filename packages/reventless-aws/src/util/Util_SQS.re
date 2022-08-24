open PulumiAws;

let service = "SQS";

let toResource = (queue: PulumiAws.SQS.Queue.t) =>
  Reventless.Adapter.resource(
    ~service=queue##name->Pulumi.Output.apply(_ => service),
    ~name=queue##name,
    ~id=queue##id,
    ~urn=queue##arn,
    ~info=queue##name->Pulumi.Output.apply(_ => ""),
  );

// Example ARN: arn:aws:sqs:eu-west-1:xxxxxx:MarketplaceServiceExtensionPointCommandTopic-0101023
let arn2Account = arn =>
  switch (arn->Js.String2.split(":")) {
  | [|_, _, _, _, account, _|] => account
  | _ => ""
  };

let subscribeToSnsTopic = (~queue, ~targetName, ~sourceName, ~topic, ~opts) =>
  SNS.TopicSubscription.make(
    ~name=sourceName ++ "2" ++ targetName,
    ~args=
      SNS.TopicSubscription.Args.make(
        ~endpoint=queue##arn->Pulumi.Output.asInput,
        ~protocol=`sqs,
        ~topic=topic##urn->Pulumi.Output.asInput,
        ~rawMessageDelivery=true->Pulumi.Input.wrap,
        (),
      ),
    ~opts=Some(opts),
  );
