module EventRule = {
  let toResource: PulumiAws.Cloudwatch.EventRule.t => ReventlessInfra.Adapter.resource = ({
    id,
    name,
    arn,
  }) =>
    ReventlessInfra.Adapter.make(
      ~name,
      ~id,
      ~urn=arn,
      ~service=name->Pulumi.Output.apply(_ => AWS.CloudwatchEventRule.service),
      ~resourceType="aws:cloudwatch:EventRule"->Pulumi.Output.make,
    )
}
