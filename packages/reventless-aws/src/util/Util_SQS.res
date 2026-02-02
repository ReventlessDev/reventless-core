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

let toResource = (queue: PulumiAws.SQS.Queue.t) => {
  ReventlessSpec.Adapter.service: queue.name->Pulumi.Output.apply(_ => AWS.SQS.service),
  name: queue.name,
  id: queue.id,
  urn: queue.arn,
  info: queue.name->Pulumi.Output.apply(_ => ""),
}

let fromResource = ({id, name}: ReventlessSpec.Adapter.resource) => {
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
  ~topic: ReventlessSpec.Adapter.resource,
  ~opts,
) =>
  SNS.TopicSubscription.make(
    ~name=sourceName->Reventless.Util.baseName ++ ("2" ++ targetName),
    ~args={
      endpoint: queue.arn->Pulumi.Output.asInput,
      protocol: SQS,
      topic: topic.urn->Pulumi.Output.asInput,
      rawMessageDelivery: true->Pulumi.Input.make,
    },
    ~opts=Some(opts),
  )

let findResource = resources => resources->Reventless.Util.Adapter.findResource(AWS.SQS.service)

let findResourceInOutput = resourcesOutput =>
  resourcesOutput->Reventless.Util.Adapter.findResourceInOutput(AWS.SQS.service)

let findUnwrappedResource = resources =>
  resources->Reventless.Util.AdapterRuntime.findUnwrappedResource(AWS.SQS.service)

module Subscription = {
  let toResource = ({eventSourceMapping: {id, arn}}: PulumiAws.SQS.Queue.eventSubscription) => {
    ReventlessSpec.Adapter.service: id->Pulumi.Output.apply(_ => AWS.SQS.service),
    name: id,
    id,
    urn: arn,
    info: id->Pulumi.Output.apply(_ => ""),
  }
}
