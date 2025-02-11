module EventRule = {
  let service = "CloudwatchEventRule"

  let toResource: PulumiAws.Cloudwatch.EventRule.t => ReventlessSpec.Adapter.resource = ({
    id,
    name,
    arn,
  }) => {
    ReventlessSpec.Adapter.service: name->Pulumi.Output.apply(_ => service),
    name,
    id,
    urn: arn,
    info: name->Pulumi.Output.apply(_ => ""),
  }
}
