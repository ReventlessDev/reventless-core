open PulumiAws;

let queue =
  SQS.Queue.make(
    ~name="DeadLetterQueue",
    ~args=
      SQS.Queue.Args.make(
        ~visibilityTimeoutSeconds=180->Pulumi.Input.wrap,
        (),
      ),
    (),
  );

let callback: Lambda.eventHandlerNoResult('a) =
  (evt, ctx) =>
    Reventless.Promise.resolved(Js.log3("DEAD LETTER ITEM:", evt, ctx))
    |> Reventless.Promise.toJs;

let name = "DeadLetterQueue";

let handler =
  PulumiAws.Lambda.CallbackFunction.make(
    ~name,
    ~args=
      PulumiAws.Lambda.CallbackFunction.Args.make(
        ~callback,
        ~policies=PulumiAws.Lambda.Policy.defaultPolicies,
        (),
      ),
    ~opts=
      Pulumi.CustomResourceOptions.make(
        ~parent=queue->PulumiAws.SQS.Queue.toResource,
        (),
      ),
    (),
  );

let subscription = queue->SQS.Queue.onEvent(~name, ~handler, ());
