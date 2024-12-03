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

let callback: Lambda.eventHandlerNoResult<'a> = (evt, ctx) =>
  Js.Promise.make((~resolve, ~reject as _) => resolve(Js.log3("DEAD LETTER ITEM:", evt, ctx)))

let handler = PulumiAws.Lambda.CallbackFunction.make(
  ~name,
  ~args=PulumiAws.Lambda.CallbackFunction.Args.make(~callback),
  ~opts={Pulumi.CustomResourceOptions.parent: queue->PulumiAws.SQS.Queue.toResource},
)

let subscription = queue->SQS.Queue.onEvent(~name, ~handler)
let fifoSubscription = fifoQueue->SQS.Queue.onEvent(~name=nameFifo, ~handler)
