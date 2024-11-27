open PulumiAws

let toResource = (queue: PulumiAws.SQS.Queue.t) => {
  ReventlessSpec.Adapter.service: queue.name->Pulumi.Output.apply(_ => Util_SQS_Runtime.service),
  name: queue.name,
  id: queue.id,
  urn: queue.arn,
  info: queue.name->Pulumi.Output.apply(_ => ""),
}

// Example ARN: arn:aws:sqs:eu-west-1:xxxxxx:MarketplaceServiceExtensionPointCommandTopic-0101023
let arn2Account = arn =>
  switch arn->Js.String2.split(":") {
  | [_, _, _, _, account, _] => account
  | _ => ""
  }

let subscribeToSnsTopic = (
  ~queue: PulumiAws.SQS.Queue.t,
  ~targetName,
  ~sourceName,
  ~topic: ReventlessSpec.Adapter.resource,
  ~opts,
) =>
  SNS.TopicSubscription.make(
    ~name=sourceName ++ ("2" ++ targetName),
    ~args={
      endpoint: queue.arn->Pulumi.Output.asInput,
      protocol: SQS,
      topic: topic.urn->Pulumi.Output.asInput,
      rawMessageDelivery: true->Pulumi.Input.make,
    },
    ~opts=Some(opts),
  )

let findResourceInOutput = resourcesOutput =>
  resourcesOutput->Reventless.Util.Adapter.findResourceInOutput(Util_SQS_Runtime.service)
