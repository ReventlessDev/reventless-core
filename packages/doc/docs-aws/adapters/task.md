---
title: "Task → Lambda + SQS"
date: 2026-01-15
draft: false
---

## Task → S3

The Task adapter provides task data storage using Amazon S3, with Lambda functions automatically triggered on object creation and deletion events. This enables event-driven task processing workflows where task data files trigger processing pipelines.

## Bucket Configuration

The Task adapter creates an S3 bucket with CORS configuration optimized for task file uploads:

```rescript
let bucket = PulumiAws.S3.Bucket.make(
  ~name,
  ~args={
    corsRules: [
      {
        PulumiAws.S3.Bucket.allowedHeaders: ["*"],
        allowedMethods: ["HEAD", "GET"],
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
  },
  ~opts,
)
```

**Configuration details:**

- **CORS rules** - Enables cross-origin resource sharing for browser-based file uploads
  - **`allowedHeaders: ["*"]`** - Accepts any HTTP headers in CORS requests
  - **`allowedMethods: ["HEAD", "GET"]`** - Supports HEAD requests (metadata) and GET requests (download)
  - **`allowedOrigins: ["*"]`** - Allows requests from any origin (configure more restrictively in production)
  - **`exposeHeaders`** - Exposes AWS-specific response headers to client JavaScript
    - `x-amz-server-side-encryption` - Encryption method used
    - `x-amz-request-id` - Request ID for debugging
    - `x-amz-id-2` - Extended request ID for support cases
    - `ETag` - Entity tag for cache validation
  - **`maxAgeSeconds: 3000`** - Browser caches CORS preflight responses for 50 minutes

**Key features:**

- **Browser upload support** - CORS configuration enables direct uploads from web applications
- **Metadata access** - Exposed headers allow client-side verification of uploads
- **CDN-friendly** - CORS settings support CloudFront distribution in front of S3

## Lambda Event Subscriptions

The Task adapter automatically subscribes Lambda functions to S3 bucket events:

```rescript
let subscribeLambda2S3Bucket = (lambda, name, bucket, opts) => {
  let _ = lambda->Pulumi.Output.apply(lambda => {
    let _subscribeResources = [
      bucket->PulumiAws.S3.Bucket.onObjectCreated(
        ~name=name ++ "Created",
        ~handler=lambda,
        ~opts
      ),
      bucket->PulumiAws.S3.Bucket.onObjectRemoved(
        ~name=name ++ "Deleted",
        ~handler=lambda,
        ~opts
      ),
    ]
  })
}
```

**Event subscriptions:**

- **`onObjectCreated`** - Lambda invoked when new objects are uploaded to the bucket
  - Triggered by `s3:ObjectCreated:*` events (Put, Post, Copy, CompleteMultipartUpload)
  - Lambda receives event with object key, bucket name, size, and metadata
  - Useful for processing newly uploaded task data files

- **`onObjectRemoved`** - Lambda invoked when objects are deleted from the bucket
  - Triggered by `s3:ObjectRemoved:*` events (Delete, DeleteMarkerCreated)
  - Lambda receives event with deleted object key and bucket name
  - Useful for cleanup operations or tracking task completion

**Key features:**

- **Automatic wiring** - S3 bucket notifications are automatically configured
- **Event filtering** - Can be extended with prefix/suffix filters for selective triggering
- **Asynchronous invocation** - Lambda is invoked asynchronously (S3 doesn't wait for response)
- **Retry handling** - Failed Lambda invocations are automatically retried by S3

## IAM Policy Configuration

The `connect` function creates comprehensive IAM policies based on the bucket access mode:

```rescript
let createLambdaPolicy = (
  lambdaRole: PulumiAws.IAM.Role.t,
  name,
  bucket: PulumiAws.S3.Bucket.t,
  bucketMode: Reventless.Task.bucketMode,
  resources: array<ReventlessSpec.Adapter.resource>,
  opts,
) => {
  let _ = (bucket.arn, resources->Reventless.Adapter.resourcesToUnwrappedOutput)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((bucketArn, resources)) => {
      let allowLambdaWriteS3 =
        bucketMode == Write || bucketMode == ReadWrite
          ? Some(PulumiAws.PolicyDocument.make(
              ~id=name ++ "WriteS3",
              ~statements=[{
                sid: "allowLambdaWriteS3",
                effect: Allow,
                actions: Actions(["s3:PutObject", "s3:DeleteObject"]),
                resources: Resource(bucketArn),
              }],
            ))
          : None

      let allowLambdaReadS3 =
        bucketMode == Read || bucketMode == ReadWrite
          ? Some(PulumiAws.PolicyDocument.make(
              ~id=name ++ "ReadS3",
              ~statements=[{
                sid: "allowLambdaReadS3",
                effect: Allow,
                actions: Actions(["s3:GetObject"]),
                resources: Resource(bucketArn),
              }],
            ))
          : None

      let allowLambdaSendSQS =
        resources->Array.length > 0
          ? Some(PulumiAws.PolicyDocument.make(
              ~id=name ++ "SendSQS",
              ~statements=[{
                sid: "AllowLambdaSendSQS",
                effect: Allow,
                actions: Action("sqs:SendMessage"),
                resources: Resources(resources->sqsResources->urns),
              }],
            ))
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
```

**Bucket access modes:**

The IAM policy is dynamically constructed based on `bucketMode`:

- **`Read`** - Grants `s3:GetObject` permission
  - Lambda can read/download objects from the bucket
  - Use for task processors that read input files

- **`Write`** - Grants `s3:PutObject` and `s3:DeleteObject` permissions
  - Lambda can upload and delete objects in the bucket
  - Use for task generators that write output files

- **`ReadWrite`** - Grants both read and write permissions
  - Lambda can read, write, and delete objects
  - Use for task processors that read inputs and write outputs

**Additional permissions:**

- **CloudWatch Logs** - `defaultLoggingPolicyDocument` grants Lambda permission to write logs
  - `logs:CreateLogGroup`
  - `logs:CreateLogStream`
  - `logs:PutLogEvents`

- **SQS SendMessage** - If `commandTopics` are provided, grants permission to send commands to SQS queues
  - Enables task processors to publish commands after processing files
  - Only added if resources array is non-empty
  - Scoped to specific SQS queue resources

**Policy merging:**

The `mergePolicyDocuments` function combines multiple policy documents into a single IAM policy:
- Logging permissions (always included)
- S3 read permissions (if `bucketMode` includes `Read`)
- S3 write permissions (if `bucketMode` includes `Write`)
- SQS send permissions (if command topics are provided)

## Connect Function

The `connect` function wires together the Task bucket, Lambda runtime, and CommandTopics:

```rescript
let connect = (
  ~name,
  ~bucket: Reventless.Task_Adapter.bucket<bucketParts>,
  ~bucketMode: Reventless.Task.bucketMode,
  ~commandTopics: Pulumi.Output.t<Reventless.CommandTopic.allOutputs>,
  ~runtime: Reventless.Runtime.environment<runtimeParts>,
  ~opts,
) => {
  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let _ = commandTopics->Pulumi.Output.apply(allCommandTopics => {
    lambda->subscribeLambda2S3Bucket(name, bucket.parts, opts)
    let resources =
      allCommandTopics
      ->Dict.valuesToArray
      ->Array.flatMap(commandTopic => commandTopic.resources)
    lambdaRole->createLambdaPolicy(name, bucket.parts, bucketMode, resources, opts)
  })
}
```

**Connection flow:**

1. **Extract Lambda resources** - Gets Lambda function and IAM role from runtime environment
2. **Subscribe to S3 events** - Configures S3 bucket to trigger Lambda on object created/deleted
3. **Collect CommandTopic resources** - Gathers SQS queue resources from all CommandTopics
4. **Create IAM policy** - Attaches policy to Lambda role with appropriate permissions

**Key features:**

- **Deferred execution** - Uses `Pulumi.Output.apply` to wait for all resources to be created
- **Dynamic permissions** - IAM policy is tailored to actual bucket mode and command topics
- **Resource tracking** - Collects all SQS resources from CommandTopics for fine-grained permissions
- **Separation of concerns** - Subscribe and policy creation are separate operations

## Runtime Event Handling

The runtime handler processes S3 bucket events and invokes user-defined callbacks:

```rescript
let handleBucketEvent = (handleEvent: Reventless.Task.bucketCallback) => (
  event: PulumiAws.S3.Bucket.event,
  _,
) => {
  event.records
  ->Array.map(record => {
    let eventName = record.eventName
    let key = Js.Global.decodeURIComponent(record.s3.object.key)
    handleEvent(~eventName, ~key)
  })
  ->Promise.all
  ->Promise.thenResolve(actions => actions->Array.flat)
}
```

**Processing flow:**

1. **Extract records** - S3 event contains array of records (typically one, but can be multiple)
2. **Decode object key** - S3 encodes object keys with URL encoding; decode to get actual file path
3. **Invoke callback** - Call user-defined `handleEvent` function with event name and object key
4. **Parallel processing** - Process all records concurrently using `Promise.all`
5. **Flatten results** - Combine actions from all records into a single flat array

**Event structure:**

S3 bucket events contain:
- **`eventName`** - Type of S3 event (e.g., `"ObjectCreated:Put"`, `"ObjectRemoved:Delete"`)
- **`s3.object.key`** - Object key (file path) that triggered the event
- **`s3.object.size`** - Size of the object in bytes
- **`s3.bucket.name`** - Name of the S3 bucket
- **`s3.bucket.arn`** - ARN of the S3 bucket

**Callback return value:**

The `handleEvent` callback returns `Promise.t<array<action>>`:
- **Actions** - Array of follow-up actions to perform (e.g., publish commands, update state)
- **Flattened results** - All actions from all records are combined into a single array
- **Sequential execution** - Framework executes actions in order after event processing completes

**Key features:**

- **URL decoding** - Handles S3's URL encoding of object keys (spaces, special characters)
- **Batch processing** - Supports multiple S3 events in a single Lambda invocation
- **Error isolation** - Failed callbacks don't prevent other records from processing (Promise.all)
- **Action composition** - Callbacks return actions for follow-up operations

## Deploy-time to Runtime Flow

The Task adapter follows the standard deploy-time/runtime pattern:

```rescript
let make: Reventless.Task_Adapter.bucketMaker<bucketParts> = (~name, ~opts) => {
  // Deploy-time: Create S3 bucket
  let bucket = PulumiAws.S3.Bucket.make(
    ~name,
    ~args={corsRules: [...]->Pulumi.Input.make},
    ~opts,
  )

  {
    resources: [bucket->Util.S3.toResource],
    parts: bucket,
  }
}

let makeHandler = handleEvents => TaskBucket_S3_Runtime.handleBucketEvent(handleEvents, ...)
```

**Flow steps:**

1. **Create S3 bucket** - Pulumi provisions the S3 bucket with CORS configuration
2. **Return bucket parts** - `parts` field contains the Pulumi S3 bucket resource
3. **Connect Lambda** - `connect` function subscribes Lambda to bucket events and creates IAM policies
4. **Bind runtime handler** - `makeHandler` creates runtime function that processes S3 events
5. **Lambda execution** - Runtime function executes in Lambda when S3 objects are created/deleted

**Adapter return value:**

```rescript
{
  resources: [bucket->Util.S3.toResource],  // For dependency tracking
  parts: bucket,                             // Pulumi S3 bucket resource
}
```

Unlike other adapters that return `operations` or `publishJson`, the Task adapter:
- Returns `parts` containing the S3 bucket resource
- Uses `connect` function to wire Lambda subscriptions and IAM policies
- Uses `makeHandler` to create runtime event processing function

## When to Use Task Buckets

**Use Task S3 buckets for:**

- **File-based workflows** - Process uploaded files (images, documents, data files)
- **Batch processing** - Trigger processing when new batch files arrive
- **ETL pipelines** - Extract data from uploaded files, transform, and load into databases
- **Document processing** - OCR, format conversion, content extraction
- **Media processing** - Thumbnail generation, video transcoding, image optimization
- **Data ingestion** - Import CSV/JSON files into read models or aggregates
- **Temporary storage** - Store intermediate processing results with lifecycle policies

**Common patterns:**

- **Upload → Process → Command** - File upload triggers Lambda, which processes file and publishes commands
- **Upload → Transform → Store** - File upload triggers transformation (resize image, transcode video) and stores result
- **Upload → Extract → Update** - File upload triggers data extraction and read model updates
- **Cleanup on delete** - Object deletion triggers cleanup operations (delete related data, update counters)

**Integration with Commands:**

Task processors often publish commands after processing files:
1. User uploads file to S3 bucket
2. S3 triggers Lambda with object created event
3. Lambda reads and processes file
4. Lambda publishes commands to CommandTopics (enabled by SQS send permissions)
5. Commands are processed by Aggregates as usual

This pattern enables event-driven architectures where file uploads initiate business workflows.

