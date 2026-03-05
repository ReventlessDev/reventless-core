let toResource = ({PulumiAws.SNS.Topic.id: id, name, arn}) => {
  let r: ReventlessInfra.Adapter.resource = {
    service: name->Pulumi.Output.apply(_ => AWS.SNS_FIFO.service),
    name,
    id,
    urn: arn,
    info: name->Pulumi.Output.apply(_ => ""),
  }
  r
}

let findTopicInResolvedResources = resources =>
  switch resources->ReventlessCore.Util_Adapter.filterSupportedResolvedResources([
    AWS.SNS_FIFO.service,
  ]) {
  | [] =>
    JsError.throwWithMessage(
      "Util.SQS_FIFO.findTopicNameInUnwrappedResources: Couldn't find SNS_FIFO Topic in resources",
    )

  | resources => resources->Array.getUnsafe(0)
  }
