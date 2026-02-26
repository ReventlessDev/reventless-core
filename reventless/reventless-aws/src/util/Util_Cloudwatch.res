module EventRule = {
  let toResource: PulumiAws.Cloudwatch.EventRule.t => Reventless.Adapter.resource = ({
    id,
    name,
    arn,
  }) => {
    Reventless.Adapter.service: name->Pulumi.Output.apply(_ => AWS.CloudwatchEventRule.service),
    name,
    id,
    urn: arn,
    info: name->Pulumi.Output.apply(_ => ""),
  }
}
