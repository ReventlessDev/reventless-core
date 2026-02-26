open PulumiAws

type channelParts = {queue: PulumiAws.SQS.Queue.t}

let toRuntimeQueueOutput = ({name, id, arn}: PulumiAws.SQS.Queue.t) =>
  (name, id, arn)
  ->Pulumi.Output.all3
  ->Pulumi.Output.apply(((name, id, arn)) => {
    Util_SQS_Runtime.id,
    name,
    arn,
  })

let toResource = (queue: PulumiAws.SQS.Queue.t): Reventless.Adapter.resource => {
  Reventless.Adapter.service: queue.name->Pulumi.Output.apply(_ => AWS.SQS.service),
  name: queue.name,
  id: queue.id,
  urn: queue.arn,
  info: queue.name->Pulumi.Output.apply(_ => ""),
}

let fromResource = ({id, name}: Reventless.Adapter.resource) => {
  name->Pulumi.Output.apply(name => PulumiAws.SQS.Queue.get(~name, ~id=id->Pulumi.Output.asInput))
}

// Example ARN: arn:aws:sqs:eu-west-1:xxxxxx:MarketplaceServiceExtensionPointCommandTopic-0101023
let arn2Account = arn =>
  switch arn->String.split(":") {
  | [_, _, _, _, account, _] => account
  | _ => ""
  }

let subscribeToSnsTopic = (
  ~queue: PulumiAws.SQS.Queue.t,
  ~targetName,
  ~sourceName,
  ~topic: Reventless.Adapter.resource,
  ~opts,
) =>
  SNS.TopicSubscription.make(
    ~name=sourceName->ReventlessCore.Util.baseName ++ ("2" ++ targetName),
    ~args={
      endpoint: queue.arn->Pulumi.Output.asInput,
      protocol: SQS,
      topic: topic.urn->Pulumi.Output.asInput,
      rawMessageDelivery: true->Pulumi.Input.make,
    },
    ~opts=Some(opts),
  )

let findResource = resources => resources->ReventlessCore.Util.Adapter.findResource(AWS.SQS.service)

let findResourceInOutput = resourcesOutput =>
  resourcesOutput->ReventlessCore.Util.Adapter.findResourceInOutput(AWS.SQS.service)

let findResolvedResource = resources =>
  resources->ReventlessCore.Util.AdapterRuntime.findResolvedResource(AWS.SQS.service)

module Subscription = {
  let toResource = ({eventSourceMapping: {id, arn}}: PulumiAws.SQS.Queue.eventSubscription): Reventless.Adapter.resource => {
    Reventless.Adapter.service: id->Pulumi.Output.apply(_ => AWS.SQS.service),
    name: id,
    id,
    urn: arn,
    info: id->Pulumi.Output.apply(_ => ""),
  }
}
