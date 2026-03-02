let toRuntimeTopicOutput = ({name, id, arn}: PulumiAws.SNS.Topic.t) =>
  (name, id, arn)
  ->Pulumi.Output.all3
  ->Pulumi.Output.apply(((name, id, arn)) => {
    Util_SNS_Runtime.id,
    name,
    arn,
  })

let toResource: PulumiAws.SNS.Topic.t => ReventlessInfra.Adapter.resource = ({id, name, arn}) => {
  ReventlessInfra.Adapter.service: name->Pulumi.Output.apply(_ => AWS.SNS.service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => ""),
}

let findResolvedResource = resources =>
  resources->ReventlessCore.Util.Adapter.findResolvedResource(AWS.SNS.service)

let findTopicInResolvedResources = resources =>
  switch resources->ReventlessCore.Util_Adapter.filterSupportedResolvedResources([AWS.SNS.service]) {
  | [] =>
    let err = "Util.SQS.findTopicNameInUnwrappedResources: Couldn't find SNS Topic in resources"
    Console.log(err)
    JsError.throwWithMessage(err)

  | resources => resources->Array.getUnsafe(0)
  }
