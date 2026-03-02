module EventRule = {
  let toResource: PulumiAws.Cloudwatch.EventRule.t => ReventlessInfra.Adapter.resource = ({
    id,
    name,
    arn,
  }) => {
    ReventlessInfra.Adapter.service: name->Pulumi.Output.apply(_ => AWS.CloudwatchEventRule.service),
    name,
    id,
    urn: arn,
    info: name->Pulumi.Output.apply(_ => ""),
  }
}
