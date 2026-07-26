type runtimeParts = Util.Lambda.runtimeParts
type callbackEvent = PulumiAws.S3.Bucket.event
type context = PulumiAws.Lambda.context
type bucketParts = PulumiAws.S3.Bucket.t

let subscribeLambda2S3Bucket = (lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>, name, bucket, opts) => {
  // Coerce Function.t → CallbackFunction.t for S3 bucket notification bindings
  // (structurally compatible: both have arn, id, name)
  let handler: Pulumi.Output.t<PulumiAws.Lambda.CallbackFunction.t> = lambda->Obj.magic
  let _ = handler->Pulumi.Output.apply(handler => {
    let _subscribeResources = [
      bucket->PulumiAws.S3.Bucket.onObjectCreated(~name=name ++ "Created", ~handler, ~opts),
      bucket->PulumiAws.S3.Bucket.onObjectRemoved(~name=name ++ "Deleted", ~handler, ~opts),
    ]
  })
}

open PulumiAws.PolicyDocument
open ReventlessCore.Adapter
open Adapter_Helpers

let createLambdaPolicy = (
  lambdaRole: PulumiAws.IAM.Role.t,
  name,
  bucket: PulumiAws.S3.Bucket.t,
  bucketMode: ReventlessCore.Task.bucketMode,
  resources: array<ReventlessInfra.Adapter.resource>,
  opts,
) => {
  let _ =
    (bucket.arn, resources->ReventlessCore.Adapter.resourcesToResolvedOutput)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((bucketArn, resources)) => {
      let allowLambdaWriteS3 =
        bucketMode == Write || bucketMode == ReadWrite
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "WriteS3",
                ~statements=[
                  {
                    sid: "allowLambdaWriteS3",
                    effect: Allow,
                    actions: Actions(["s3:PutObject", "s3:DeleteObject"]),
                    resources: Resource(bucketArn),
                  },
                ],
              ),
            )
          : None
      let allowLambdaReadS3 =
        bucketMode == Read || bucketMode == ReadWrite
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "ReadS3",
                ~statements=[
                  {
                    sid: "allowLambdaReadS3",
                    effect: Allow,
                    actions: Actions(["s3:GetObject"]),
                    resources: Resource(bucketArn),
                  },
                ],
              ),
            )
          : None
      let allowLambdaSendSQS =
        resources->Array.length > 0
          ? {
              Some(
                PulumiAws.PolicyDocument.make(
                  ~id=name ++ "SendSQS",
                  ~statements=[
                    {
                      sid: "AllowLambdaSendSQS",
                      effect: Allow,
                      actions: Action("sqs:SendMessage"),
                      resources: Resources(resources->sqsResources->urns),
                    },
                  ],
                ),
              )
            }
          : None

      let _lambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name,
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [
              Some(PulumiAws.Lambda.defaultLoggingPolicyDocument),
              allowLambdaReadS3,
              allowLambdaWriteS3,
              allowLambdaSendSQS,
            ]->Array.keepSome,
          )->Pulumi.Output.asInput,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )
    })
}

let connect = (
  ~name,
  ~bucket: ReventlessCore.Task_Adapter.bucket<bucketParts>,
  ~bucketMode: ReventlessCore.Task.bucketMode,
  ~commandTopics: Pulumi.Output.t<ReventlessCore.CommandTopic.allOutputs>,
  ~runtime: ReventlessCore.Runtime.environment<runtimeParts>,
  ~opts,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let _ = commandTopics->Pulumi.Output.apply(allCommandTopics => {
    lambda->subscribeLambda2S3Bucket(name, bucket.parts, opts)
    let resources =
      allCommandTopics->Dict.valuesToArray->Array.flatMap(commandTopic => commandTopic.resources)
    lambdaRole->createLambdaPolicy(name, bucket.parts, bucketMode, resources, opts)
  })
}

let make: ReventlessCore.Task_Adapter.bucketMaker<bucketParts> = (~name, ~opts) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let bucket = {
    PulumiAws.S3.Bucket.make(
      ~name,
      ~args={
        corsRules: [
          {
            PulumiAws.S3.Bucket.allowedHeaders: ["*"],
            allowedMethods: ["HEAD", "GET", "PUT", "POST"],
            allowedOrigins: ["*"],
            exposeHeaders: [
              "x-amz-server-side-encryption",
              "x-amz-request-id",
              "x-amz-id-2",
              "ETag",
            ],
            maxAgeSeconds: 3000,
          },
        ]->Pulumi.Input.make,
        tags: AWS.Tags.make(~name, ~kind=ReventlessCore.Task.componentType, ~role=Other("Bucket")),
      },
      ~opts,
    )
  }

  {
    resources: [bucket->Util.S3.toResource],
    parts: bucket,
  }
}

let makeHandler = handleEvents => TaskBucket_S3_Runtime.handleBucketEvent(handleEvents, ...)
