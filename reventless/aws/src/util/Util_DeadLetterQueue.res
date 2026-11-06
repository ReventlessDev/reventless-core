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

// 14 days, the SQS maximum, stated rather than inherited. A dead letter is the
// only surviving evidence of a message the system could not process, and the
// 4-day default can expire it over a long weekend before anyone reads it.
let retentionSeconds = 14 * 24 * 60 * 60

// How many times a consuming queue delivers a message before it moves it here; every redrive
// policy in the framework takes it from here. Defined beside the handler, which needs it.
let maxReceiveCount = Util_DeadLetterHandler.maxReceiveCount

// A dead letter has no latency requirement, and the handler below fails on
// purpose — so a message returns to the queue and is redelivered until retention
// expires. At 180 s that is ~480 redeliveries per message per day, which outlives
// the fault by however long nobody looks: seven heartbeats stranded by a since-fixed
// decode error were still cycling twelve hours after the cause was cured. Fifteen
// minutes cuts that 5× and costs nothing anybody is waiting on. It must stay above
// the handler's timeout (30 s), which it is by a wide margin.
//
// It bounds the rate, not the count — the loop still ends only at retention. What
// ends it early is an operator, and what fetches one is an alarm on this handler's
// `Invocations` (an invocation here IS the incident). That the alarm does not
// currently fire is a defect in when this module announces itself, not a reason
// for the queue to carry a redrive target of its own.
let visibilityTimeoutSeconds = 15 * 60

let queue = SQS.Queue.make(
  ~name,
  ~args={
    SQS.Queue.visibilityTimeoutSeconds: visibilityTimeoutSeconds->Pulumi.Input.make,
    messageRetentionSeconds: retentionSeconds->Pulumi.Input.make,
    sqsManagedSseEnabled: false->Pulumi.Input.make,
    tags: queueTags(name),
  },
)

let fifoQueue = SQS.Queue.make(
  ~name=nameFifo,
  ~args={
    SQS.Queue.fifoQueue: true->Pulumi.Input.make,
    contentBasedDeduplication: true->Pulumi.Input.make,
    visibilityTimeoutSeconds: visibilityTimeoutSeconds->Pulumi.Input.make,
    messageRetentionSeconds: retentionSeconds->Pulumi.Input.make,
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

// The function's whole code is `Util_DeadLetterHandler`'s compiled file, which imports
// nothing (see there), shipped as `index.mjs`. It sits beside `Util_Bundle`'s compiled file,
// so it resolves from there.
let entryPointCode = NodeFs.readFileSync(
  Util_Bundle.localRequire->NodeModule.requireResolve("./Util_DeadLetterHandler.res.mjs"),
)

let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
archiveContents->Dict.set(
  "index.mjs",
  Pulumi.Asset.stringAsset(entryPointCode)->Pulumi.Archive.assetToAssetOrArchive,
)
let code = Pulumi.Archive.assetArchive(archiveContents)
let sourceCodeHash = Util_Bundle.hashString(entryPointCode)

let layers = Lambda.reventlessLayers()

// This is the one Lambda in the framework built by hand rather than through
// `RuntimeEnvironment_Lambda`, and it was the one Lambda whose logs Lambda
// auto-created a group for — which carries no retention, so every byte this
// handler ever wrote was kept forever. On the estate that surfaced it, the three
// such groups held 1.3 GB of a redelivery loop. Same managed group, same tiering
// as every other handler.
let logGroup = Util_LambdaLogging.makeManagedLogGroup(
  ~name,
  ~tags=AWS.Tags.make(
    ~name=`${name}LogGroup`,
    ~kind=ReventlessCore.ComponentType.Plugin,
    ~role=Logs,
    ~scope=Plugin,
  ),
  ~opts,
  (),
)

let handler = Lambda.Function.make(
  ~name,
  ~args={
    handler: "index.handler"->Pulumi.Input.make,
    runtime: Util_LambdaRuntime.node->Pulumi.Input.make,
    code: code->Pulumi.Input.make,
    sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
    role: lambdaRole.arn->Pulumi.Output.asInput,
    memorySize: 128->Pulumi.Input.make,
    timeout: 30->Pulumi.Input.make,
    layers,
    tags: AWS.Tags.make(
      ~name,
      ~kind=ReventlessCore.ComponentType.Plugin,
      ~role=DeadLetter,
      ~scope=Plugin,
    ),
    environment: (
      {
        Lambda.Function.variables: Dict.fromArray([
          ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
          Util_LambdaLogging.logLevelEntry(),
        ]),
      }: Lambda.Function.functionEnvironment
    )->Pulumi.Input.make,
    loggingConfig: ?Util_LambdaLogging.loggingConfigFor(logGroup),
  },
  ~opts,
)

// Second Monitoring provisioning site: the dead-letter mechanism. Role-based
// kind, mechanism-agnostic resource — no-op unless a backend is registered.
let deadLetterResource = Util_Lambda.functionToResource(
  handler,
  ~tags=AWS.Tags.make(
    ~name,
    ~kind=ReventlessCore.ComponentType.Plugin,
    ~role=DeadLetter,
    ~scope=Plugin,
  )->Pulumi.Output.fromInput,
)

ReventlessCore.Monitoring.notify(
  ~kind=DeadLetterSink,
  ~name,
  ~component=deadLetterResource,
  ~logLocator=Util_LambdaLogging.logLocatorFor(~logGroup, ~physicalName=deadLetterResource.name),
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
