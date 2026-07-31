// Typed cold-start core for the TaskBucket Lambda entry point.
//
// The "typed core, thin shell" split (docs/plans/minimize-lambda-entrypoint-mjs-shell.md):
// TaskBucketEntryPoint.mjs keeps only the inherently-untyped seam — the
// dynamic `import()` of the task callback module named in HANDLER_CONFIG and
// the read of its `callback` export. HANDLER_CONFIG parsing, the S3-event →
// task-action dispatch (an exhaustive match over Reventless.Task.taskAction —
// the former JS `switch (action.TAG)` with its unreachable "unknown TAG" arm), the
// per-aggregate command publishing, and the CloudWatch Events scheduler ops
// live here, fully type-checked.
//
// The former `.mjs` carried a hand-maintained mirror of
// `toScheduleExpression` ("kept in sync manually"); typed code calls
// ScheduledPublisher_CloudWatchEvents_Runtime directly — the layer ships it —
// so the mirror is gone.

@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logWarn: (string, StreamRoutedEntryPoint_Ops.dispatchOpts) => unit = "warn"

// ── HANDLER_CONFIG ──────────────────────────────────────────────────────────
// Written by TaskRuntime_Builder_PerBucket.

type schedulerEnvConfig = {
  roleArnEnv: string,
  targetArnEnv: string,
  targetNameEnv: string,
}
type handlerConfig = {
  callbackModule: string,
  // aggregateName → env-var name holding the aggregate's cmd-topic SQS URL.
  publishToAggregates: dict<string>,
  scheduler: option<schedulerEnvConfig>,
}

let strOf = (obj: dict<JSON.t>, key: string): option<string> =>
  obj->Dict.get(key)->Option.flatMap(JSON.Decode.string)

let parseHandlerConfig = (rawJson: string): handlerConfig => {
  let obj =
    (rawJson == "" ? "{}" : rawJson)
    ->JSON.parseOrThrow
    ->JSON.Decode.object
    ->Option.getOr(Dict.make())
  {
    callbackModule: obj->strOf("callbackModule")->Option.getOr(""),
    publishToAggregates: obj
    ->Dict.get("publishToAggregates")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.getOr(Dict.make())
    ->Dict.toArray
    ->Array.filterMap(((k, v)) => v->JSON.Decode.string->Option.map(s => (k, s)))
    ->Dict.fromArray,
    scheduler: obj
    ->Dict.get("scheduler")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.map(s => {
      roleArnEnv: s->strOf("roleArnEnv")->Option.getOr(""),
      targetArnEnv: s->strOf("targetArnEnv")->Option.getOr(""),
      targetNameEnv: s->strOf("targetNameEnv")->Option.getOr(""),
    }),
  }
}

// ── Command publishing ──────────────────────────────────────────────────────
// aggregateName → publishJsons, resolving each queue URL via the env-var name
// carried in HANDLER_CONFIG; entries with an unset or empty URL are skipped
// (same as the former JS `if (queueUrl !== "")`).

let buildPublishCommands = (map: dict<string>): dict<ReventlessCore.CommandTopic.publishJsons> =>
  map
  ->Dict.toArray
  ->Array.filterMap(((aggName, envVarName)) =>
    NodeProcess.env
    ->Dict.get(envVarName)
    ->Option.filter(queueUrl => queueUrl != "")
    ->Option.map(queueUrl => {
      let queue: Util_SQS_Runtime.resolvedQueue = {id: queueUrl, name: queueUrl, arn: ""}
      (aggName, queue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO))
    })
  )
  ->Dict.fromArray

// ── Scheduler ops (CloudWatch Events) ───────────────────────────────────────
// Resolved lazily on the first schedule action (tasks without schedules never
// touch the CloudWatch client) and cached for the container lifetime.

type schedulerOps = {
  createSchedule: Reventless.Schedule.schedule => promise<unit>,
  deleteSchedule: string => promise<unit>,
}

let schedulerOpsCache: ref<option<schedulerOps>> = ref(None)

let makeSchedulerOps = (config: option<schedulerEnvConfig>): option<schedulerOps> =>
  switch (schedulerOpsCache.contents, config) {
  | (Some(ops), _) => Some(ops)
  | (None, None) => None
  | (None, Some(cfg)) =>
    switch (
      NodeProcess.env->Dict.get(cfg.roleArnEnv),
      NodeProcess.env->Dict.get(cfg.targetArnEnv),
      NodeProcess.env->Dict.get(cfg.targetNameEnv),
    ) {
    | (Some(roleArn), Some(targetArn), Some(targetName))
      if roleArn != "" && targetArn != "" && targetName != "" =>
      // The single resolved resource the shared CloudWatch Events runtime
      // targets: `urn` is the PutTargets ARN, `name` the target id.
      let resources: array<ReventlessInfra.Adapter.resolvedResource> = [
        {
          name: targetName,
          id: targetName,
          urn: targetArn,
          service: "unknown",
          resourceInfo: ReventlessInfra.Adapter.NoInfo,
          role: "",
          region: "",
          resourceType: "",
          configuration: Dict.make(),
          tags: Dict.make(),
        },
      ]
      let ops = {
        createSchedule: schedule =>
          ScheduledPublisher_CloudWatchEvents_Runtime.createSchedule(~roleArn)(resources, schedule),
        deleteSchedule: name =>
          ScheduledPublisher_CloudWatchEvents_Runtime.deleteSchedule(resources, name),
      }
      schedulerOpsCache := Some(ops)
      Some(ops)
    | _ =>
      logWarn("scheduler env vars missing — schedules will no-op", {comp: "TaskBucketRuntime"})
      None
    }
  }

// ── Task-action dispatch ────────────────────────────────────────────────────

let dispatchTaskActions = async (
  ~actions: array<Reventless.Task.taskAction>,
  ~publishCommands: dict<ReventlessCore.CommandTopic.publishJsons>,
  ~schedulerOps: unit => option<schedulerOps>,
): unit => {
  let _ =
    await actions
    ->Array.map(async action =>
      switch action {
      | Reventless.Task.PublishCommands(aggregateName, cmdJsons) =>
        switch publishCommands->Dict.get(aggregateName) {
        | Some(publish) => await publish(cmdJsons)
        | None =>
          logWarn(
            `no publish function for aggregate "${aggregateName}"`,
            {comp: "TaskBucketRuntime"},
          )
        }
      | CreateSchedule(schedule) =>
        switch schedulerOps() {
        | Some(ops) => await ops.createSchedule(schedule)
        | None =>
          logWarn(
            "CreateSchedule skipped — no scheduler configured for this Task (add sideEffects to setup)",
            {comp: "TaskBucketRuntime"},
          )
        }
      | DeleteSchedule(name) =>
        switch schedulerOps() {
        | Some(ops) => await ops.deleteSchedule(name)
        | None =>
          logWarn(
            "DeleteSchedule skipped — no scheduler configured for this Task (add sideEffects to setup)",
            {comp: "TaskBucketRuntime"},
          )
        }
      }
    )
    ->Promise.all
}

// ── Exported Lambda handler ─────────────────────────────────────────────────
// The shell reads `callback` off the dynamically imported task module and
// hands it here; from this point everything is typed
// (TaskBucket_S3_Runtime.handleBucketEvent decodes the S3 records and invokes
// the callback per object).

let makeHandler = (~callback: ReventlessCore.Task.bucketCallback, ~config: handlerConfig) => {
  let handleEvents = TaskBucket_S3_Runtime.handleBucketEvent(callback)
  let publishCommands = buildPublishCommands(config.publishToAggregates)
  async (event: PulumiAws.S3.Bucket.event, context: PulumiAws.Lambda.context) => {
    let actions = await handleEvents(event, context)
    await dispatchTaskActions(
      ~actions,
      ~publishCommands,
      ~schedulerOps=() => makeSchedulerOps(config.scheduler),
    )
    ""
  }
}
