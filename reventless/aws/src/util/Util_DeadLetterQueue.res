// TODO: move DeadLetterQueue creation into separate Adapter and use it from Plugin_Builder
open PulumiAws

let name = "DeadLetterQueue"
let nameFifo = "FIFO" ++ name

let queueTags = queueName =>
  AWS.Tags.make(
    ~name=queueName,
    ~kind=ReventlessCore.ComponentType.Plugin,
    ~role=DeadLetter,
    ~scope=Plugin,
  )

let queue = SQS.Queue.make(
  ~name,
  ~args={
    SQS.Queue.visibilityTimeoutSeconds: 180->Pulumi.Input.make,
    sqsManagedSseEnabled: false->Pulumi.Input.make,
    tags: queueTags(name),
  },
)

let fifoQueue = SQS.Queue.make(
  ~name=nameFifo,
  ~args={
    SQS.Queue.fifoQueue: true->Pulumi.Input.make,
    contentBasedDeduplication: true->Pulumi.Input.make,
    visibilityTimeoutSeconds: 180->Pulumi.Input.make,
    sqsManagedSseEnabled: false->Pulumi.Input.make,
    tags: queueTags(nameFifo),
  },
)

let opts = {Pulumi.CustomResourceOptions.parent: queue->PulumiAws.SQS.Queue.toResource}
let lambdaRole = IAM.Role.makeWithDefaultPolicy(
  ~name,
  ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
  ~tags=AWS.Tags.make(
    ~name,
    ~kind=ReventlessCore.ComponentType.Plugin,
    ~role=Identity,
    ~scope=Plugin,
  ),
  ~opts,
)

let entryPointCode = `export const handler = async (event) => {
  console.error("DEAD LETTER ITEM:", JSON.stringify(event));
};`

let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
archiveContents->Dict.set(
  "index.mjs",
  Pulumi.Asset.stringAsset(entryPointCode)->Pulumi.Archive.assetToAssetOrArchive,
)
let code = Pulumi.Archive.assetArchive(archiveContents)
let sourceCodeHash = Util_Bundle.hashString(entryPointCode)

let layers =
  Lambda.reventlessLayerArn
  ->Option.map(arn => [arn->Pulumi.Input.make])
  ->Option.getOr([])
  ->Pulumi.Input.make

let handler = Lambda.Function.make(
  ~name,
  ~args={
    handler: "index.handler"->Pulumi.Input.make,
    runtime: "nodejs22.x"->Pulumi.Input.make,
    code: code->Pulumi.Input.make,
    sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
    role: lambdaRole.arn->Pulumi.Output.asInput,
    memorySize: 128->Pulumi.Input.make,
    timeout: 30->Pulumi.Input.make,
    layers,
    tags: AWS.Tags.make(~name, ~kind=ReventlessCore.ComponentType.Plugin, ~role=DeadLetter, ~scope=Plugin),
    environment: (
      {
        Lambda.Function.variables: Dict.fromArray([
          ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
        ]),
      }: Lambda.Function.functionEnvironment
    )->Pulumi.Input.make,
  },
  ~opts,
)

// Second Monitoring provisioning site (§2): the dead-letter mechanism. Role-based
// kind, mechanism-agnostic resource — no-op unless a backend is registered.
ReventlessCore.Monitoring.notify(
  ~kind=DeadLetterSink,
  ~name,
  ~component=Util_Lambda.functionToResource(
    handler,
    ~tags=AWS.Tags.make(~name, ~kind=ReventlessCore.ComponentType.Plugin, ~role=DeadLetter, ~scope=Plugin)->Pulumi.Output.fromInput,
  ),
)

let lambda = handler->Pulumi.Output.make

let esmTags = esmName =>
  AWS.Tags.make(
    ~name=esmName,
    ~kind=ReventlessCore.ComponentType.Plugin,
    ~role=EventSourceMapping,
    ~scope=Plugin,
  )

let _subscription = Util_EventSourceMapping.subscribeSqs(
  ~lambda,
  ~name,
  ~queue,
  ~tags=esmTags(name),
  ~opts,
)
let _fifoSubscription = Util_EventSourceMapping.subscribeSqs(
  ~lambda,
  ~name=nameFifo,
  ~queue=fifoQueue,
  ~tags=esmTags(nameFifo),
  ~opts,
)
let createQueuePolicyDocument = (name, queueArn: string, handlerArn: string) => {
  open PulumiAws.PolicyDocument
  PulumiAws.PolicyDocument.make(
    ~id=name ++ "QueuePolicy",
    ~statements=[
      {
        sid: "AllowLambdaToAccessQueue",
        effect: Allow,
        principal: Principals({
          service: PrincipalId(AWS.Lambda.principal),
        }),
        actions: Actions(["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]),
        resources: Resource(queueArn),
        conditions: {
          arnEquals: Dict.fromArray([("AWS:SourceArn", ConditionValue(handlerArn))]),
        },
      },
    ],
  )
  ->PulumiAws.PolicyDocument.toJsonString
  ->Pulumi.Input.make
}

let _ =
  (queue.id, queue.arn, fifoQueue.id, fifoQueue.arn, handler.arn)
  ->Pulumi.Output.all5
  ->Pulumi.Output.apply(((_queueId, queueArn, _fifoQueueId, fifoQueueArn, handlerArn)) => {
    let lambdaPolicyDocument = PulumiAws.PolicyDocument.make(
      ~id=name ++ "SQSPolicy",
      ~statements=[
        {
          sid: "AllowLambdaSendAndReceiveMessage",
          effect: Allow,
          actions: Actions([
            "sqs:ReceiveMessage",
            "sqs:DeleteMessage",
            "sqs:GetQueueAttributes",
            "sqs:ChangeMessageVisibility",
          ]),
          resources: Resources([queueArn, fifoQueueArn]),
        },
      ],
    )

    let _attachLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
      ~name,
      ~args={
        policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
          name ++ "LambdaPolicy",
          [PulumiAws.Lambda.defaultLoggingPolicyDocument, lambdaPolicyDocument],
        )->Pulumi.Output.asInput,
        role: lambdaRole.id->Pulumi.Output.asInput,
      },
      ~opts,
    )

    // `queueUrl` takes the queue's Output, not the resolved `queueId` string:
    // that is what registers the policy -> queue dependency, without which
    // Pulumi has no ordering constraint and can delete the queue first on a
    // replacement, leaving the policy's delete polling a queue that is gone.
    //
    // Unlike the channel helpers, these two stay inside the apply. This module
    // creates its resources at import time and this apply resolves late enough
    // to race Jest's teardown; reshaping it (dropping the now-unused ids to
    // narrow the tuple) shifts that timing and crashes the AWS unit suites, so
    // `_queueId` / `_fifoQueueId` are deliberately kept.
    let _attachQueuePolicy = PulumiAws.SQS.QueuePolicy.make(
      ~name,
      ~args={
        queueUrl: queue.id->Pulumi.Output.asInput,
        policy: createQueuePolicyDocument(name, queueArn, handlerArn),
      },
      ~opts=Some(opts),
    )
    let _attachFifoQueuePolicy = PulumiAws.SQS.QueuePolicy.make(
      ~name=nameFifo,
      ~args={
        queueUrl: fifoQueue.id->Pulumi.Output.asInput,
        policy: createQueuePolicyDocument(nameFifo, fifoQueueArn, handlerArn),
      },
      ~opts=Some(opts),
    )
  })
