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

// Logs what arrived, then FAILS the invocation on purpose.
//
// Returning success here would let SQS delete the message, which is what this
// handler used to do — and it made a dead letter unobservable twice over: the
// queue's depth returned to 0, so a depth alarm could never fire, and the
// function's `Errors` metric stayed at 0, so neither could an error alarm. A
// plugin whose commands failed every 5 minutes for two days produced 217 dead
// letters and no signal at all; it was found by a person noticing a stale UI.
//
// Failing instead keeps the message on the queue and keeps `Errors` non-zero
// while the condition lasts. Both are conventional alarm subjects, and a
// monitoring backend attached through the `DeadLetterSink` seam below now has
// something to attach to.
//
// What that reasoning did not account for is that the transport retries by
// design too: a failed batch returns to the queue and is redelivered until
// retention expires. A handler that fails forever, on a transport that retries
// forever, is a loop — and it outlives its cause, because nothing about a fixed
// bug removes the message that was stranded by it. Seven of them were still
// cycling twelve hours after the fix that made them impossible.
//
// What the loop costs is now a function of the line, not the count: the full
// record is written once — on the first delivery, the one carrying the diagnostic
// — and every redelivery after it costs a single identity line. A stranded
// message is ~150 KB over a fortnight rather than ~17 MB, which is small enough
// that ending the loop early is an operator's job rather than the topology's.
let entryPointCode = `export const handler = async (event) => {
  const records = event?.Records ?? [];
  for (const record of records) {
    const attrs = record?.attributes ?? {};
    const receiveCount = Number(attrs.ApproximateReceiveCount ?? 1);
    const identity =
      "messageId=" + (record?.messageId ?? "unknown") +
      " source=" + (attrs.DeadLetterQueueSourceArn ?? record?.eventSourceARN ?? "unknown") +
      " receiveCount=" + receiveCount +
      " bodyBytes=" + (record?.body?.length ?? 0);
    if (receiveCount <= 1) {
      console.error("DEAD LETTER ITEM: " + identity, JSON.stringify(record));
    } else {
      console.error("DEAD LETTER REDELIVERY: " + identity);
    }
  }
  throw new Error(
    "Dead-lettered " + records.length +
    " message(s); see DEAD LETTER ITEM above. Failing so the messages are retained and Errors is non-zero."
  );
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
  ~tags=AWS.Tags.make(~name, ~kind=ReventlessCore.ComponentType.Plugin, ~role=DeadLetter, ~scope=Plugin)->Pulumi.Output.fromInput,
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
