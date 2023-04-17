let service = "SNS_FIFO"

let toResource = (topic: PulumiAws.SNS.Topic.t) =>
  Reventless.Adapter.resource(
    ~service=topic["name"]->Pulumi.Output.apply(_ => service),
    ~name=topic["name"],
    ~id=topic["id"],
    ~urn=topic["arn"],
    ~info=topic["name"]->Pulumi.Output.apply(_ => ""),
  )

let findTopicInUnwrappedResources = resources =>
  switch resources->Reventless.Util_Adapter.filterSupportedUnwrappedResources([service]) {
  | [] =>
    let err = "Util.SQS_FIFO.findTopicNameInUnwrappedResources: Couldn't find SNS_FIFO Topic in resources"
    Js.log(err)
    Js.Exn.raiseError(err)

  | resources => resources[0]
  }
