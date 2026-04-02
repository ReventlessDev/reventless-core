let toResource = (~tags=?, {PulumiAws.SNS.Topic.id: id, name, arn}) =>
  ReventlessInfra.Adapter.make(
    ~name,
    ~id,
    ~urn=arn,
    ~service=name->Pulumi.Output.apply(_ => AWS.SNS_FIFO.service),
    ~resourceType="aws:sns:Topic"->Pulumi.Output.make,
    ~tags=?tags,
  )

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
