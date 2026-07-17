// B3.0 — projection delivery on Postgres platforms
// (docs/plans/aws-postgres-querydb-adapter.md).
//
// On DynamoDB platforms the ReadModel / StateViewSlice Lambdas consume their
// source event logs via DynamoDB-stream event-source mappings. Postgres logs have
// no streams — instead the shared `PgChangeFeedRelay` fans every Postgres log's
// events out to one SQS "feed queue" per consumer Lambda, registered here and
// read by `Platform.provisionPgChangeFeedRelay`. Handlers are keyed by the feed
// queue's ARN (the sourceUrn analogue of the stream ARN), and per-projection
// filtering happens in the callbacks (meta.service / event-type matching), so
// delivering a log's events to a consumer that doesn't project them is a no-op —
// the same property the DynamoDB path relies on when several read models share
// one source stream.
//
// Checkpoints: each (feed queue, log) pair drains under subscriber
// `<scope>:<logName>` — per-log isolation, same rule as the EventCollector relay
// targets (the subscription tables key by subscriber alone).

type feedQueue = {
  /** Subscriber prefix — the checkpoint key is `<scope>:<logName>` per relayed log. */
  scope: string,
  /** Relay classic `event_log` logs into this queue. */
  includeClassic: bool,
  /** Relay DCB `dcb_event` logs into this queue. */
  includeDcb: bool,
  url: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
}

let feedQueues: array<feedQueue> = []

/** All registered feed queues (read by `Platform.provisionPgChangeFeedRelay`). */
let getFeedQueues = (): array<feedQueue> => feedQueues

/** Create a consumer Lambda's feed queue and register it for relay fan-out.
    ESM + IAM attach separately via `connect` once the Lambda exists. */
let makeQueue = (
  ~name: string,
  ~scope: string,
  ~includeClassic: bool,
  ~includeDcb: bool,
  ~opts: Pulumi.CustomResourceOptions.t,
): PulumiAws.SQS.Queue.t => {
  let queue = PulumiAws.SQS.Queue.make(
    ~name,
    ~args={
      PulumiAws.SQS.Queue.visibilityTimeoutSeconds: 120->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.queue.arn
      ->Pulumi.Output.apply(dlqArn =>
        PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
    },
    ~opts,
  )
  feedQueues
  ->Array.push({scope, includeClassic, includeDcb, url: queue.id, arn: queue.arn})
  ->ignore
  queue
}

/** Wire a feed queue into its consumer Lambda: SQS event-source mapping +
    receive IAM on the Lambda role. */
let connect = (
  ~name: string,
  ~queue: PulumiAws.SQS.Queue.t,
  ~lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>,
  ~lambdaRole: PulumiAws.IAM.Role.t,
  ~opts: Pulumi.CustomResourceOptions.t,
) => {
  let _esm = Util_EventSourceMapping.subscribeSqs(~lambda, ~name, ~queue, ~opts)
  let _policy = queue.arn->Pulumi.Output.apply(queueArn => {
    open PulumiAws.PolicyDocument
    PulumiAws.IAM.RolePolicy.make(
      ~name=`${name}Receive`,
      ~args={
        policy: PulumiAws.PolicyDocument.make(
          ~id=`${name}ReceivePolicy`,
          ~statements=[
            {
              sid: "AllowReceiveFeedQueue",
              effect: Allow,
              actions: Actions([
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes",
              ]),
              resources: Resource(queueArn),
            },
          ],
        )
        ->PulumiAws.PolicyDocument.toJsonString
        ->Pulumi.Input.make,
        role: lambdaRole.id->Pulumi.Output.asInput,
      },
      ~opts,
    )
  })
}
