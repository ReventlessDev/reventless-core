// The claim component: an uploaded object stops being provisional when a
// committed event references it.
//
// Deploy-time half of [docs/plans/done/upload-pending-claim-and-expiry.md] Step 2.
// `make` registers one event log whose events declare at least one
// `@storageRef` field; `finish` builds the single Lambda that serves all of
// them, its stream subscriptions, its IAM, and the alarm on how far behind it
// is. Registered from the platform's subscription hook and finished from inside
// it, for the same reason `StateTopic_AppSync` is: the hook fires from within a
// `Pulumi.Output.apply` chain, so a `finish` called after `P.make()` returns
// would drain an empty registry.
//
// It is not a plugin's concern in the domain sense — a ref minted by one plugin
// can be referenced by another's event, and no plugin owns a store's contents —
// but it is provisioned per plugin stack, because that is where the event log
// tables and their streams exist. The store side (bucket and served prefix)
// crosses in from the platform stack, which is where stores are provisioned.
//
// Input breadth is the thing to guard. Only event logs with a declared
// ref-bearing field are registered, and within one only the declared fields are
// read; if this ever grows toward "read every event" it has become a projection
// and belongs in that machinery instead.

open PulumiAws

// ── Registry ─────────────────────────────────────────────────────────────────

type entry = {
  /** The event log's DynamoDB table. Doubles as the routing key: the handler
      recovers it from each record's `eventSourceARN`. */
  tableName: Pulumi.Output.t<string>,
  streamArn: Pulumi.Output.t<string>,
  refFields: array<ReventlessCore.StorageRefFields.eventRefFields>,
}

/** One registry per plugin — one claimer Lambda per plugin stack. `make`
    appends, `finish` drains. */
let registry: dict<array<entry>> = Dict.make()

/** Event logs that declare a ref-bearing field but publish through a channel
    this component cannot read (an SNS-backed event topic rather than a
    DynamoDB stream). Their objects stay tagged forever, which is safe while the
    lifecycle rule is off and data loss once it is on — so the deploy says so. */
let unreachable: dict<array<string>> = Dict.make()

let log = ReventlessCore.Logger.fromEnv()

let appendTo = (reg: dict<array<'a>>, key: string, value: 'a) =>
  reg->Dict.set(key, reg->Dict.get(key)->Option.getOr([])->Array.concat([value]))

// ── Registration ─────────────────────────────────────────────────────────────

/**
Register one event log with the plugin's claimer.

`~eventSchema` is read for `@storageRef` declarations; an event log with none is
not registered at all, so a platform whose plugins declare no store provisions
no claimer. `~plugin` qualifies a store the annotation left unqualified, which
is the same resolution the deploy used when it provisioned the store.

`~isStreamBacked` says whether the event log's topic publishes through a
DynamoDB stream — the default for both aggregate and DCB logs — rather than
SNS. Decided by the caller because the platform already makes exactly that
call synchronously from `EventTopicPublisher_SNS`'s registry; asking the
resource here would only get the answer inside an `apply`, which is after
`finish` has drained the registry.
*/
let make = (
  ~plugin: string,
  ~eventLogName: string,
  ~eventSchema: S.t<unknown>,
  ~eventTopicOutputs: ReventlessInfra.EventTopic.outputs,
  ~isStreamBacked: bool,
) => {
  let refFields = ReventlessCore.StorageRefFields.fromEventSchema(~plugin, eventSchema)
  if refFields->Array.length > 0 {
    // An SNS-backed topic carries the same events, but not on a channel this
    // Lambda subscribes to. Recorded as a gap rather than skipped in silence:
    // its objects would keep the pending tag forever, which reads as "working"
    // right up until a store enables expiry.
    switch isStreamBacked ? eventTopicOutputs.resources->Array.get(0) : None {
    | None => unreachable->appendTo(plugin, eventLogName)
    | Some(streamResource) =>
      registry->appendTo(
        plugin,
        {
          tableName: streamResource.name,
          streamArn: streamResource->Util_DynamoDbStream.streamArnFromDynamoDbTableResource,
          refFields,
        },
      )
    }
  }
}

// ── Finalize ─────────────────────────────────────────────────────────────────

/** A store the claimer may untag in, resolved to what the handler needs. */
type storeConfig = {
  qualified: string,
  bucketName: string,
  servedPrefix: string,
}

/**
Build the plugin's claimer from everything `make` registered.

`~stores` is the platform's declared object stores — in a plugin stack they
arrive from the platform stack's `objectStores` export, which is why it is an
Output. A thunk rather than the Output itself because most plugins register
nothing here, and resolving another stack's export to build a claimer that is
not going to exist is work with no reader.

`~iteratorAgeAlarmMs` is the lag the alarm fires at. Lag is the one failure mode
that deletes data: if this Lambda stops and nobody notices, referenced objects
keep the tag and an enabled lifecycle rule expires them. The default is an hour
against an expiry measured in days, so a stall is noticed with room to fix it.
*/
let finish = (
  ~plugin: string,
  ~stores: unit => Pulumi.Output.t<array<storeConfig>>,
  ~iteratorAgeAlarmMs: float=3_600_000.,
  ~opts: Pulumi.CustomResourceOptions.t,
) => {
  switch unreachable->Dict.get(plugin)->Option.filter(logs => logs->Array.length > 0) {
  | Some(logs) =>
    log.warn(
      ~comp="Upload_Claim",
      `event log(s) ${logs->Array.join(", ")} declare storage-ref fields but publish through an ` ++
      `SNS event topic, which the claimer does not subscribe to — objects those events reference ` ++
      `keep the pending tag. Do not enable a store's expiry rule while this is true.`,
    )
    unreachable->Dict.set(plugin, [])
  | _ => ()
  }

  switch registry->Dict.get(plugin) {
  | None | Some([]) => ()
  | Some(entries) =>
    let name = plugin ++ "UploadClaim"
    let stores = stores()

    let lambdaRole = IAM.Role.makeWithDefaultPolicy(
      ~name=name ++ "Role",
      ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
      ~tags=AWS.Tags.make(
        ~name=name ++ "Role",
        ~kind=ReventlessCore.ComponentType.Plugin,
        ~role=Identity,
        ~component=name,
      ),
      ~opts,
    )

    // Read every registered stream; tag and untag under every declared store's
    // served prefix, never a whole bucket. `GetObjectTagging` is what makes the
    // untag a read-modify-write that preserves a deployment's own tags rather
    // than a `DeleteObjectTagging` that would take them with it.
    let _policy =
      (entries->Array.map(e => e.streamArn)->Pulumi.Output.all, stores)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((streamArns, stores)) => {
        open PolicyDocument
        let objectArns =
          stores->Array.map(s => `arn:aws:s3:::${s.bucketName}/${s.servedPrefix}/*`)
        let _rolePolicy = IAM.RolePolicy.make(
          ~name=name ++ "Policy",
          ~args={
            policy: PolicyDocument.make(
              ~id=name ++ "Policy",
              ~statements=[
                {
                  sid: "AllowLambdaLogging",
                  effect: Allow,
                  actions: Actions([
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents",
                  ]),
                  resources: Resource("arn:aws:logs:*:*:*"),
                },
                {
                  sid: "AllowReadEventLogStream",
                  effect: Allow,
                  actions: Actions([
                    "dynamodb:DescribeStream",
                    "dynamodb:GetRecords",
                    "dynamodb:GetShardIterator",
                    "dynamodb:ListStreams",
                  ]),
                  resources: Resources(streamArns),
                },
                {
                  sid: "AllowClaimObjectTagging",
                  effect: Allow,
                  actions: Actions(["s3:GetObjectTagging", "s3:PutObjectTagging"]),
                  resources: Resources(objectArns),
                },
              ],
            )
            ->PolicyDocument.toJsonString
            ->Pulumi.Input.make,
            role: lambdaRole.id->Pulumi.Output.asInput,
          },
          ~opts,
        )
      })

    // `CLAIM_REF_FIELDS` — `{ <tableName>: { <eventType>: [refField] } }`. The
    // whole of the handler's input: a table absent here is a table it reads no
    // record from.
    let refFieldsJson =
      entries
      ->Array.map(e => e.tableName)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(tableNames => {
        let byTable = Dict.make()
        tableNames->Array.forEachWithIndex((tableName, i) =>
          byTable->Dict.set(
            tableName,
            ReventlessCore.StorageRefFields.toJson((entries->Array.getUnsafe(i)).refFields),
          )
        )
        byTable->JSON.Encode.object->JSON.stringify
      })

    // `UPLOAD_STORES` — the same qualified-name → {bucket, prefix} shape the
    // presign service reads, so mint and claim resolve a store identically.
    let uploadStoresJson =
      stores->Pulumi.Output.apply(stores =>
        stores
        ->Array.map(s => (
          s.qualified,
          Dict.fromArray([
            ("bucket", JSON.Encode.string(s.bucketName)),
            ("prefix", JSON.Encode.string(s.servedPrefix)),
          ])->JSON.Encode.object,
        ))
        ->Dict.fromArray
        ->JSON.Encode.object
        ->JSON.stringify
      )

    // Compiled EntryPoint rather than a serialized closure, for the reason the
    // presign service is one: the handler reaches the AWS SDK v3 S3 client, and
    // a serialized closure bakes the deploy machine's SDK internals into an
    // archive that then resolves its transitives from independently-versioned
    // layer sources that disagree at cold start. The bundled `_Ops` module keeps
    // bare `@aws-sdk/*` imports and resolves them through the resolve-hook, so
    // one internally consistent SDK loads.
    let packageDirs = Dict.fromArray([
      (
        "@reventlessdev/reventless-aws",
        Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
      ),
    ])
    let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
      ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Upload/Upload_Claim_S3_Ops.res.mjs",
      ~packageDirs,
    )

    let layers =
      Lambda.reventlessLayerArn
      ->Option.map(arn => [arn->Pulumi.Input.make])
      ->Option.getOr([])
      ->Pulumi.Input.make

    let lambda = Lambda.Function.make(
      ~name,
      ~args={
        handler: "index.handler"->Pulumi.Input.make,
        runtime: "nodejs22.x"->Pulumi.Input.make,
        code: code->Pulumi.Input.make,
        sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
        role: lambdaRole.arn->Pulumi.Output.asInput,
        memorySize: 256->Pulumi.Input.make,
        timeout: 60->Pulumi.Input.make,
        layers,
        tags: AWS.Tags.make(
          ~name,
          ~kind=ReventlessCore.ComponentType.Plugin,
          ~role=Runtime,
          ~component=name,
        ),
        environment: (
          {
            Lambda.Function.variables: Dict.fromArray([
              ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
              ("UPLOAD_STORES", uploadStoresJson->Pulumi.Output.asInput),
              ("CLAIM_REF_FIELDS", refFieldsJson->Pulumi.Output.asInput),
              ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
              ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
              Util_LambdaLogging.logLevelEntry(),
            ]),
          }: Lambda.Function.functionEnvironment
        )->Pulumi.Input.make,
      },
      ~opts,
    )

    Util_LambdaLogging.makeManagedLogGroup(
      ~name,
      ~lambdaName=lambda.name,
      ~tags=AWS.Tags.make(
        ~name=name ++ "LogGroup",
        ~kind=ReventlessCore.ComponentType.Plugin,
        ~role=Logs,
        ~component=name,
      ),
      ~opts,
      (),
    )

    // One mapping per event log stream, all targeting the one Lambda.
    // `maximumRetryAttempts` bounds a permanently failing record so it cannot
    // wedge the shard — the default of -1 retries forever, which would turn one
    // bad record into unbounded claim lag, which is the failure that deletes
    // data. `bisectBatchOnFunctionError` isolates it across those retries.
    entries->Array.forEachWithIndex((entry, i) => {
      let esmName = `${name}Stream${i->Int.toString}`
      let _esm = EventSourceMapping.make(
        ~name=esmName,
        ~args={
          EventSourceMapping.functionName: lambda.arn->Pulumi.Output.asInput,
          eventSourceArn: entry.streamArn->Pulumi.Output.asInput,
          startingPosition: LATEST,
          maximumRetryAttempts: 3,
          bisectBatchOnFunctionError: true,
          tags: AWS.Tags.make(
            ~name=esmName,
            ~kind=ReventlessCore.ComponentType.Plugin,
            ~role=EventSourceMapping,
            ~component=name,
          ),
        },
        ~opts=Some(opts),
      )
    })

    // How far behind the claimer is, alarmed rather than merely emitted.
    // `IteratorAge` is the stream consumer's own lag and needs no custom metric;
    // `treatMissingData: "notBreaching"` keeps a quiet platform — no events, so
    // no data points — out of alarm.
    let _alarm = Cloudwatch.MetricAlarm.make(
      ~name=name ++ "Lag",
      ~args={
        comparisonOperator: "GreaterThanThreshold"->Pulumi.Input.make,
        evaluationPeriods: 3->Pulumi.Input.make,
        metricName: "IteratorAge"->Pulumi.Input.make,
        namespace: "AWS/Lambda"->Pulumi.Input.make,
        period: 300->Pulumi.Input.make,
        statistic: "Maximum"->Pulumi.Input.make,
        threshold: iteratorAgeAlarmMs->Pulumi.Input.make,
        dimensions: lambda.name
        ->Pulumi.Output.apply(fn => Dict.fromArray([("FunctionName", fn)]))
        ->Pulumi.Output.asInput,
        treatMissingData: "notBreaching"->Pulumi.Input.make,
        alarmDescription: (`${name} is behind on committed events. While it is behind, objects an ` ++
        `event already references still carry the pending tag — and a store with an expiry rule ` ++
        `enabled will delete them.`)->Pulumi.Input.make,
        tags: AWS.Tags.make(
          ~name=name ++ "Lag",
          ~kind=ReventlessCore.ComponentType.Plugin,
          ~role=Other("Alarm"),
          ~component=name,
        ),
      },
      ~opts,
    )

    // Drain, so a second construction in the same process (tests, dev reload)
    // starts from empty rather than re-registering every stream.
    registry->Dict.set(plugin, [])
  }
}
