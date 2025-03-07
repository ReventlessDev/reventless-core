let toResource = ({PulumiAws.SNS.Topic.id: id, name, arn}) => {
  ReventlessSpec.Adapter.service: name->Pulumi.Output.apply(_ => AWS.SNS_FIFO.service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => ""),
}

let findTopicInUnwrappedResources = resources =>
  switch resources->Reventless.Util_Adapter.filterSupportedUnwrappedResources([
    AWS.SNS_FIFO.service,
  ]) {
  | [] =>
    let err = "Util.SQS_FIFO.findTopicNameInUnwrappedResources: Couldn't find SNS_FIFO Topic in resources"
    Js.log(err)
    Js.Exn.raiseError(err)

  | resources => resources->Array.getUnsafe(0)
  }
