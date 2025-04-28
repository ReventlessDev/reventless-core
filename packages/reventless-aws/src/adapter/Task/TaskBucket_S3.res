type runtimeParts = Util.Lambda.runtimeParts
type callbackEvent = PulumiAws.S3.Bucket.event
type context = PulumiAws.Lambda.context
type bucketParts = PulumiAws.S3.Bucket.t

let connect = (
  ~name,
  ~bucket: Reventless.Task_Adapter.bucket<bucketParts>,
  ~runtime: Reventless.Runtime.environment<runtimeParts>,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let _ = lambda->Pulumi.Output.apply(lambda => {
    let _subscribeResources = [
      bucket.parts->PulumiAws.S3.Bucket.onObjectCreated(
        ~name=name ++ "Created",
        ~handler=lambda,
        ~opts,
      ),
      bucket.parts->PulumiAws.S3.Bucket.onObjectRemoved(
        ~name=name ++ "Deleted",
        ~handler=lambda,
        ~opts,
      ),
    ]
  })
}

let make: Reventless.Task_Adapter.bucketMaker<bucketParts> = (~name, ~opts) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let bucket = {
    PulumiAws.S3.Bucket.make(
      ~name=name ++ "Bucket",
      ~args={
        corsRules: [
          {
            PulumiAws.S3.Bucket.allowedHeaders: ["*"],
            allowedMethods: ["HEAD", "GET"],
            allowedOrigins: ["*"],
            exposeHeaders: [
              "x-amz-server-side-encryption",
              ">x-amz-request-id",
              "x-amz-id-2",
              "ETag",
            ],
            maxAgeSeconds: 3000,
          },
        ]->Pulumi.Input.make,
      },
      ~opts,
    )
  }

  {
    resources: [bucket->Util.S3.toResource],
    parts: bucket,
  }
}

let makeHandler = handleEvents =>
  (TaskBucket_S3_Runtime.handleBucketEvent(handleEvents, ...))->Pulumi.Output.make
