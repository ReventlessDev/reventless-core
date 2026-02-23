type runtimeParts = Util.Lambda.runtimeParts
type callbackEvent = PulumiAws.S3.Bucket.event
type context = PulumiAws.Lambda.context
type bucketParts = PulumiAws.S3.Bucket.t

let subscribeLambda2S3Bucket = (lambda, name, bucket, opts) => {
  let _ = lambda->Pulumi.Output.apply(lambda => {
    let _subscribeResources = [
      bucket->PulumiAws.S3.Bucket.onObjectCreated(~name=name ++ "Created", ~handler=lambda, ~opts),
      bucket->PulumiAws.S3.Bucket.onObjectRemoved(~name=name ++ "Deleted", ~handler=lambda, ~opts),
    ]
  })
}

open PulumiAws.PolicyDocument
open Reventless.Adapter
open Adapter_Helpers

let createLambdaPolicy = (
  lambdaRole: PulumiAws.IAM.Role.t,
  name,
  bucket: PulumiAws.S3.Bucket.t,
  bucketMode: Reventless.Task.bucketMode,
  resources: array<ReventlessSpec.Adapter.resource>,
  opts,
) => {
  let _ =
    (bucket.arn, resources->Reventless.Adapter.resourcesToUnwrappedOutput)
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
  ~bucket: Reventless.Task_Adapter.bucket<bucketParts>,
  ~bucketMode: Reventless.Task.bucketMode,
  ~commandTopics: Pulumi.Output.t<Reventless.CommandTopic.allOutputs>,
  ~runtime: Reventless.Runtime.environment<runtimeParts>,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let _ = commandTopics->Pulumi.Output.apply(allCommandTopics => {
    lambda->subscribeLambda2S3Bucket(name, bucket.parts, opts)
    let resources =
      allCommandTopics->Dict.valuesToArray->Array.flatMap(commandTopic => commandTopic.resources)
    lambdaRole->createLambdaPolicy(name, bucket.parts, bucketMode, resources, opts)
  })
}

let make: Reventless.Task_Adapter.bucketMaker<bucketParts> = (~name, ~opts) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let bucket = {
    PulumiAws.S3.Bucket.make(
      ~name,
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

let makeHandler = handleEvents => TaskBucket_S3_Runtime.handleBucketEvent(handleEvents, ...)
