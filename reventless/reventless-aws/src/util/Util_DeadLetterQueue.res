// TODO: move DeadLetterQueue creation into separate Adapter and use it from Plugin_Builder
open PulumiAws

let name = "DeadLetterQueue"
let nameFifo = "FIFO" ++ name

let queue = SQS.Queue.make(
  ~name,
  ~args={
    SQS.Queue.visibilityTimeoutSeconds: 180->Pulumi.Input.make,
    sqsManagedSseEnabled: false->Pulumi.Input.make,
  },
)

let fifoQueue = SQS.Queue.make(
  ~name=nameFifo,
  ~args={
    SQS.Queue.fifoQueue: true->Pulumi.Input.make,
    contentBasedDeduplication: true->Pulumi.Input.make,
    visibilityTimeoutSeconds: 180->Pulumi.Input.make,
    sqsManagedSseEnabled: false->Pulumi.Input.make,
  },
)

let opts = {Pulumi.CustomResourceOptions.parent: queue->PulumiAws.SQS.Queue.toResource}
let lambdaRole = IAM.Role.makeWithDefaultPolicy(
  ~name,
  ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
  ~opts,
)

let entryPointCode = `export const handler = async (event) => {
  console.error("DEAD LETTER ITEM:", JSON.stringify(event));
};`

let code = Util_Bundle.bundleEntryPoint(entryPointCode)

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
    role: lambdaRole.arn->Pulumi.Output.asInput,
    memorySize: 128->Pulumi.Input.make,
    timeout: 30->Pulumi.Input.make,
    layers,
    tags: AWS.Tags.make(~name, ReventlessCore.CommandTopic.componentType),
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

let lambda = handler->Pulumi.Output.make

let _subscription = Util_EventSourceMapping.subscribeSqs(~lambda, ~name, ~queue, ~opts)
let _fifoSubscription = Util_EventSourceMapping.subscribeSqs(
  ~lambda,
  ~name=nameFifo,
  ~queue=fifoQueue,
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
  ->Pulumi.Output.apply(((queueId, queueArn, fifoQueueId, fifoQueueArn, handlerArn)) => {
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

    let _attachQueuePolicy = PulumiAws.SQS.QueuePolicy.make(
      ~name,
      ~args={
        queueUrl: queueId->Pulumi.Input.make,
        policy: createQueuePolicyDocument(name, queueArn, handlerArn),
      },
      ~opts=Some(opts),
    )
    let _attachFifoQueuePolicy = PulumiAws.SQS.QueuePolicy.make(
      ~name=nameFifo,
      ~args={
        queueUrl: fifoQueueId->Pulumi.Input.make,
        policy: createQueuePolicyDocument(nameFifo, fifoQueueArn, handlerArn),
      },
      ~opts=Some(opts),
    )
  })
