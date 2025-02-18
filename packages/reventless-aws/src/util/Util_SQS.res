open PulumiAws

let toRuntimeQueueOutput = ({name, id, arn}: PulumiAws.SQS.Queue.t) =>
  [name, id, arn]
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(([name, id, arn]) => {
    Util_SQS_Runtime.id,
    name,
    arn,
  })

let toResource = (queue: PulumiAws.SQS.Queue.t) => {
  ReventlessSpec.Adapter.service: queue.name->Pulumi.Output.apply(_ => Util_SQS_Runtime.service),
  name: queue.name,
  id: queue.id,
  urn: queue.arn,
  info: queue.name->Pulumi.Output.apply(_ => ""),
}

let fromResource = ({urn, id, name}: ReventlessSpec.Adapter.resource) => {
  PulumiAws.SQS.Queue.name,
  id,
  arn: urn,
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

let findResource = resources =>
  resources->Reventless.Util.Adapter.findResource(Util_SQS_Runtime.service)

let findResourceInOutput = resourcesOutput =>
  resourcesOutput->Reventless.Util.Adapter.findResourceInOutput(Util_SQS_Runtime.service)

@obj
external makeQueue: (
  ~arn: Pulumi.Output.t<string>,
  ~name: Pulumi.Output.t<string>,
  ~id: Pulumi.Output.t<string>,
) => PulumiAws.SQS.Queue.t = ""

let fromResource = (resource: ReventlessSpec.Adapter.resource) =>
  makeQueue(~id=resource.id, ~name=resource.name, ~arn=resource.urn)
