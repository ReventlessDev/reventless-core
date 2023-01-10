open PulumiAws;

let name = "DeadLetterQueue";
let nameFifo = "FIFO" ++ name;

let queue =
  SQS.Queue.make(
    ~name,
    ~args=
      SQS.Queue.Args.make(
        ~visibilityTimeoutSeconds=180->Pulumi.Input.wrap,
        ~sqsManagedSseEnabled=false->Pulumi.Input.wrap,
        (),
      ),
    (),
  );

let fifoQueue =
  SQS.Queue.make(
    ~name=nameFifo,
    ~args=
      SQS.Queue.Args.make(
        ~fifoQueue=true->Pulumi.Input.wrap,
        ~contentBasedDeduplication=true->Pulumi.Input.wrap,
        ~visibilityTimeoutSeconds=180->Pulumi.Input.wrap,
        ~sqsManagedSseEnabled=false->Pulumi.Input.wrap,
        (),
      ),
    (),
  );

// let make: ((~resolve: (. 'a) => unit, ~reject: (. exn) => unit) => unit) => t<'a>
let callback: Lambda.eventHandlerNoResult('a) =
  (evt, ctx) =>
    Js.Promise.make((~resolve, ~reject as _) =>
      resolve(. Js.log3("DEAD LETTER ITEM:", evt, ctx))
    );

// NOTE: since there is no component for the DeadLetterQueue we don't use resources here
//       but we should still SOMEWHERE collect this lambda resource
let handler =
  PulumiAws.Lambda.CallbackFunction.make(
    ~name,
    ~args=PulumiAws.Lambda.CallbackFunction.Args.make(~callback, ()),
    ~opts=
      Pulumi.CustomResourceOptions.make(
        ~parent=queue->PulumiAws.SQS.Queue.toResource,
        (),
      ),
    (),
  );

let subscription = queue->SQS.Queue.onEvent(~name, ~handler, ());
let fifoSubscription =
  fifoQueue->SQS.Queue.onEvent(~name=nameFifo, ~handler, ());
