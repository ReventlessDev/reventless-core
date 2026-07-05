// Deploy-time builder for the Postgres change-feed relay (B2.3b).
//
// Provisions a scheduled, in-VPC Lambda that drains each Postgres DCB log via
// PgChangeFeed and relays events to the plugin EventCollector SQS queue — which
// fans out to read-model projections, aggregate command topics, and the
// cross-plugin SNS EventTopic. The platform (D1, B2.3c) calls this with the set of
// Postgres-backed DCB logs and points the EventCollector's event source at the
// relay-fed queue.
//
// NOTE: EventBridge rate rules have a 1-minute floor, so v1 poll latency is
// >= 1 minute. Sub-minute latency needs a self-invoking loop / EventBridge
// Scheduler (follow-up) or the Fargate-LISTEN upgrade.

// Which Postgres feed a relay log drains.
type feed =
  /** `dcb_event` log; the partition tag is sury-encoded into HANDLER_CONFIG so the
      relay computes the same `id` (partition key) the DynamoDB-stream path would. */
  | Dcb({partitionTag: Reventless.DcbTag.derivedPartitionTag})
  /** Classic `event_log` log (one per aggregate); the stored payload already is
      the DynamoDB item shape, so no extra config is needed. */
  | Classic

// One Postgres-backed log to relay.
type relayLog = {
  connectionConfig: Pulumi.Output.t<PgConnection.connectionConfig>,
  /** dcb_event.log_name / event_log.log_name discriminator. */
  logName: string,
  /** dcb_subscription / event_log_subscription checkpoint key for this relay.
      Both tables key by subscriber alone, so this MUST be unique per log. */
  subscriber: string,
  feed: feed,
  /** Plugin EventCollector SQS queue this log's events are relayed to. */
  targetQueueUrl: Pulumi.Output.t<string>,
  targetQueueArn: Pulumi.Output.t<string>,
}

// ~securityGroupId: DB-access SG the relay Lambda attaches (PgConnection.securityGroupId).
// ~subnetIds: private subnets for the relay Lambda (PgConnection.subnetIds).
let make = (
  ~name: string,
  ~logs: array<relayLog>,
  ~securityGroupId: Pulumi.Output.t<string>,
  ~subnetIds: array<Pulumi.Input.t<string>>,
  ~intervalMinutes: int=1,
  ~opts=?,
): array<ReventlessInfra.Adapter.resource> => {
  open PulumiAws
  let customOpts =
    opts->Option.map(ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/PgChangeFeedRelayEntryPoint.mjs",
    ~packageDirs=Dict.make(),
  )

  // HANDLER_CONFIG.logs[], serialized from the deploy-time-resolved Outputs.
  let logJsonOutputs = logs->Array.map(l =>
    (l.connectionConfig, l.targetQueueUrl)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((cc, queueUrl)) => {
      let pgConnectionJson =
        [
          ("host", cc.host->JSON.Encode.string),
          ("port", cc.port->Int.toFloat->JSON.Encode.float),
          ("database", cc.database->JSON.Encode.string),
          ("username", cc.username->JSON.Encode.string),
          ("secretArn", cc.secretArn->JSON.Encode.string),
        ]
        ->Dict.fromArray
        ->JSON.Encode.object
      let entries = [
        ("pgConnection", pgConnectionJson),
        ("logName", l.logName->JSON.Encode.string),
        ("subscriber", l.subscriber->JSON.Encode.string),
        ("targetQueueUrl", queueUrl->JSON.Encode.string),
      ]
      switch l.feed {
      | Dcb({partitionTag}) =>
        entries
        ->Array.push((
          "partitionTag",
          partitionTag->S.reverseConvertToJsonOrThrow(Reventless.DcbTag.derivedPartitionTagSchema),
        ))
        ->ignore
      | Classic => entries->Array.push(("kind", "classic"->JSON.Encode.string))->ignore
      }
      entries
      ->Dict.fromArray
      ->JSON.Encode.object
      ->JSON.stringify
    })
  )
  let handlerConfigOutput =
    Pulumi.Output.all(logJsonOutputs)->Pulumi.Output.apply(items =>
      `{"logs":[${items->Array.join(",")}]}`
    )

  let envVars = Dict.fromArray([("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)])

  let vpcConfig =
    securityGroupId
    ->Pulumi.Output.apply(sgId =>
      (
        {
          Lambda.Function.subnetIds: subnetIds->Pulumi.Input.make,
          securityGroupIds: [sgId->Pulumi.Input.make]->Pulumi.Input.make,
        }: Lambda.Function.vpcConfig
      )
    )
    ->Pulumi.Output.asInput

  let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
    ~name,
    ~code,
    ~sourceCodeHash,
    ~envVars,
    ~vpcConfig,
    ~opts?,
  )

  // IAM: GetSecretValue on each log's DB secret + SendMessage on each target queue.
  let secretArns =
    logs->Array.map(l => l.connectionConfig->Pulumi.Output.apply(cc => cc.secretArn))
  let queueArns = logs->Array.map(l => l.targetQueueArn)
  let _iam =
    (Pulumi.Output.all(secretArns), Pulumi.Output.all(queueArns), runtime.parts.lambdaRole.id)
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply(((secretArns, queueArns, roleId)) => {
      open PulumiAws.PolicyDocument
      let _ = PulumiAws.IAM.RolePolicy.make(
        ~name=`${name}RelayAccess`,
        ~args={
          policy: PulumiAws.PolicyDocument.make(
            ~id=`${name}RelayAccessPolicy`,
            ~statements=[
              {
                sid: "AllowGetSecret",
                effect: Allow,
                actions: Action("secretsmanager:GetSecretValue"),
                resources: Resources(secretArns),
              },
              {
                sid: "AllowSendSqs",
                effect: Allow,
                actions: Action("sqs:SendMessage"),
                resources: Resources(queueArns),
              },
            ],
          )
          ->PulumiAws.PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: roleId->Pulumi.Input.make,
        },
      )
    })

  // Scheduled poll: EventRule (rate) → Permission → EventTarget.
  let rule = {
    open PulumiAws.Cloudwatch
    EventRule.make(
      ~name=`${Pulumi.Pulumi.getStackName()}-${name}`,
      ~args={
        description: "Poll Postgres DCB change feed and relay to EventCollector"->Pulumi.Input.make,
        scheduleExpression: EventRule.ScheduleExpression.every(Minutes(intervalMinutes)),
      },
      ~opts=?customOpts,
    )
  }

  let lambda = runtime.parts.lambda
  let _wire =
    (lambda->Pulumi.Output.flatMap(l => l.arn), lambda->Pulumi.Output.flatMap(l => l.name))
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((lambdaArn, lambdaName)) => {
      let _permission = PulumiAws.Lambda.Permission.make(
        ~name=`${name}SchedulePermission`,
        ~args={
          action: "lambda:InvokeFunction",
          function: lambdaName->Pulumi.Input.make,
          principal: AWS.CloudwatchEventRule.principal,
        },
        ~opts=?customOpts,
      )
      let _target = {
        open PulumiAws.Cloudwatch
        EventTarget.make(
          ~name,
          ~args={
            rule: EventTarget.Rule.ofEventRule(rule),
            arn: lambdaArn->Pulumi.Input.make,
          },
          ~opts=?customOpts,
        )
      }
    })

  [
    lambda
    ->Pulumi.Output.apply(l => l->Util_Lambda.toResource)
    ->ReventlessCore.Adapter.outputToResource,
    rule->Util_Cloudwatch.EventRule.toResource,
  ]
}
