let toResource: PulumiAws.S3.Bucket.t => ReventlessInfra.Adapter.resource = ({id, arn}) =>
  ReventlessInfra.Adapter.make(
    ~name=id,
    ~id,
    ~urn=arn,
    ~service=id->Pulumi.Output.apply(_ => AWS.S3.service),
    ~resourceType="aws:s3:Bucket"->Pulumi.Output.make,
  )

let toResolvedBucketOutput = ({id, arn}: PulumiAws.S3.Bucket.t) =>
  (id, arn)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((id, arn)) => {
    Util_S3_Runtime.id,
    name: id,
    arn,
  })
