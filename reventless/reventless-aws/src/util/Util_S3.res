let toResource: PulumiAws.S3.Bucket.t => Reventless.Adapter.resource = ({id, arn}) => {
  Reventless.Adapter.service: id->Pulumi.Output.apply(_ => AWS.S3.service),
  name: id,
  id,
  urn: arn,
  info: id->Pulumi.Output.apply(_ => ""),
}

let toRuntimeBucketOutput = ({id, arn}: PulumiAws.S3.Bucket.t) =>
  (id, arn)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((id, arn)) => {
    Util_S3_Runtime.id,
    name: id,
    arn,
  })
