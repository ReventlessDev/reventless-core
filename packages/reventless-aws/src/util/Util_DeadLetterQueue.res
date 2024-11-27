open PulumiAws

let name = "DeadLetterQueue"
let nameFifo = "FIFO" ++ name

Js.log("Util_DeadletterQueue: creating queue ...")
let queue = SQS.Queue.make(
  ~name,
  ~args={
    SQS.Queue.visibilityTimeoutSeconds: 180->Pulumi.Input.make,
    sqsManagedSseEnabled: false->Pulumi.Input.make,
  },
)
let _ = queue.arn->Pulumi.Output.apply(_ => Js.log("Util_DeadletterQueue: created queue"))

Js.log("Util_DeadletterQueue: creating fifoQueue ...")
let fifoQueue = SQS.Queue.make(
  ~name=nameFifo,
  ~args={
    SQS.Queue.fifoQueue: true->Pulumi.Input.make,
    contentBasedDeduplication: true->Pulumi.Input.make,
    visibilityTimeoutSeconds: 180->Pulumi.Input.make,
    sqsManagedSseEnabled: false->Pulumi.Input.make,
  },
)
let _ = fifoQueue.arn->Pulumi.Output.apply(_ => Js.log("Util_DeadletterQueue: created fifoQueue"))

let callback: Lambda.eventHandlerNoResult<'a> = (evt, ctx) =>
  Js.Promise.make((~resolve, ~reject as _) => resolve(Js.log3("DEAD LETTER ITEM:", evt, ctx)))

Js.log("Util_DeadletterQueue: creating handler ...")
let handler = PulumiAws.Lambda.CallbackFunction.make(
  ~name,
  ~args=PulumiAws.Lambda.CallbackFunction.Args.make(~callback),
  ~opts={Pulumi.CustomResourceOptions.parent: queue->PulumiAws.SQS.Queue.toResource},
)
let _ = handler.arn->Pulumi.Output.apply(_ => Js.log("Util_DeadletterQueue: created handler"))

Js.log("Util_DeadletterQueue: creating subscription ...")
let subscription = queue->SQS.Queue.onEvent(~name, ~handler)
let _ =
  subscription.eventSourceMapping.id->Pulumi.Output.apply(_ =>
    Js.log("Util_DeadletterQueue: created subscription")
  )
Js.log("Util_DeadletterQueue: creating fifoSubscription ...")
let fifoSubscription = fifoQueue->SQS.Queue.onEvent(~name=nameFifo, ~handler)
let _ =
  fifoSubscription.eventSourceMapping.id->Pulumi.Output.apply(_ =>
    Js.log("Util_DeadletterQueue: created fifoSubscription")
  )
