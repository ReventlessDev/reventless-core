let toResolvedTopicOutput = ({name, id, arn}: PulumiAws.SNS.Topic.t) =>
  (name, id, arn)
  ->Pulumi.Output.all3
  ->Pulumi.Output.apply(((name, id, arn)) => {
    Util_SNS_Runtime.id,
    name,
    arn,
  })

let toResource: PulumiAws.SNS.Topic.t => ReventlessInfra.Adapter.resource = ({id, name, arn}) =>
  ReventlessInfra.Adapter.make(
    ~name,
    ~id,
    ~urn=arn,
    ~service=name->Pulumi.Output.apply(_ => AWS.SNS.service),
    ~resourceType="aws:sns:Topic"->Pulumi.Output.make,
  )

let findResolvedResource = resources =>
  resources->ReventlessCore.Util.Adapter.findResolvedResource(AWS.SNS.service)

let log = ReventlessCore.Logger.fromEnv()

let findTopicInResolvedResources = resources =>
  switch resources->ReventlessCore.Util_Adapter.filterSupportedResolvedResources([AWS.SNS.service]) {
  | [] =>
    let err = "Couldn't find SNS Topic in resources"
    log.error(~comp="SNS", err)
    JsError.throwWithMessage(err)

  | resources => resources->Array.getUnsafe(0)
  }
