/** A CloudWatch log group that **adopts an existing group instead of failing**.

    `Cloudwatch.LogGroup` cannot: its create is `CreateLogGroup`, which fails
    `ResourceAlreadyExistsException` when the group is already there, and the
    failure does not heal on retry because the group persists. That is fatal
    wherever the deploy cannot get in first — an AppSync API's group name is
    `/aws/appsync/apis/<server-assigned id>`, so the group can only ever be
    created after the API, and any request the API serves in between makes the
    group before the deploy reaches it. From then on every deploy of that stack
    fails on the group rather than on whatever it was actually changing.

    The obvious mechanism, Pulumi's `import` resource option, does not reach this
    case. `import` takes a plan-time `string`, and neither half is one: deciding
    whether the group exists means awaiting `getLogGroup` (a `Promise`, or an
    `Output`) inside a synchronous resource declaration, and the AppSync group's
    name is itself an `Output` of the api id. Passing `import` unconditionally is
    not a fallback — importing something absent is its own error.

    So this provider removes the decision rather than making it. Retention and
    tags are applied with calls that do not care whether the group already
    exists (`CreateLogGroup` tolerated when it reports `ResourceAlreadyExists`,
    then `PutRetentionPolicy` / `TagResource`), which makes create idempotent by
    construction: nothing has to be known synchronously, and the group name can
    be an `Output` because it arrives as a resource *input* rather than a
    resource *option*.

    Delete tears the group down, so teardown behaves as the declarative resource
    did and `unmanagedLogGroupStacks` keeps its meaning. Adoption is reported at
    info level, so a deploy that adopts says so rather than passing silently.

    **Lambda does not need this.** There the deploy names the group itself and
    creates it before the function that writes to it, under a name AWS never
    mints — see `Util_LambdaLogging`. Ordering is the better fix where ordering
    is available; this is for where it is not.

    Caveat inherited from every Pulumi dynamic provider: the whole captured
    closure is serialised into stack state, and `create`/`update`/`delete`/`read`
    run the **serialised** version, not current source. A fix here reaches a
    given resource only once that resource is next created or updated. Keep each
    step able to handle state written by earlier versions. */

let log = ReventlessCore.Logger.fromEnv()

// ── AWS SDK bindings (lazily imported — see AppSync_SourceApiAssociation_Retrying) ──

type logsClient

type nameInput = {logGroupName: string}
type createInput = {logGroupName: string, tags?: dict<string>}
type retentionInput = {logGroupName: string, retentionInDays: int}
type tagInput = {resourceArn: string, tags: dict<string>}
type describeInput = {logGroupNamePrefix: string}

type logGroupSummary = {
  logGroupName?: string,
  arn?: string,
  retentionInDays?: int,
}
type describeResult = {logGroups?: array<logGroupSummary>}

type createCmd
type retentionCmd
type deleteRetentionCmd
type tagCmd
type describeCmd
type deleteCmd

// Shape of the dynamically-imported `@aws-sdk/client-cloudwatch-logs` module.
type sdkModule = {
  @as("CloudWatchLogsClient") clientCtor: unit => logsClient,
  @as("CreateLogGroupCommand") createCtor: createInput => createCmd,
  @as("PutRetentionPolicyCommand") retentionCtor: retentionInput => retentionCmd,
  @as("DeleteRetentionPolicyCommand") deleteRetentionCtor: nameInput => deleteRetentionCmd,
  @as("TagResourceCommand") tagCtor: tagInput => tagCmd,
  @as("DescribeLogGroupsCommand") describeCtor: describeInput => describeCmd,
  @as("DeleteLogGroupCommand") deleteCtor: nameInput => deleteCmd,
}

@module("./Util_LogGroup_Adopting_Js.mjs") external newCommand: ('ctor, 'arg) => 'cmd = "newCommand"
@module("./Util_LogGroup_Adopting_Js.mjs") external newClient: 'ctor => logsClient = "newClient"
@module("./Util_LogGroup_Adopting_Js.mjs") external rethrow: JsExn.t => 'a = "rethrow"

@send external sendCreate: (logsClient, createCmd) => promise<unit> = "send"
@send external sendRetention: (logsClient, retentionCmd) => promise<unit> = "send"
@send external sendDeleteRetention: (logsClient, deleteRetentionCmd) => promise<unit> = "send"
@send external sendTag: (logsClient, tagCmd) => promise<unit> = "send"
@send external sendDescribe: (logsClient, describeCmd) => promise<describeResult> = "send"
@send external sendDelete: (logsClient, deleteCmd) => promise<unit> = "send"

// Dynamic ESM import — emitted as a literal `import("...")` so the Pulumi
// serialiser does not statically capture the SDK in the provider closure.
@val external dynImport: string => promise<sdkModule> = "import"

let _sdk: ref<option<sdkModule>> = ref(None)
let _client: ref<option<logsClient>> = ref(None)

let getSdk = async (): sdkModule =>
  switch _sdk.contents {
  | Some(m) => m
  | None =>
    let m = await dynImport("@aws-sdk/client-cloudwatch-logs")
    _sdk.contents = Some(m)
    m
  }

let getClient = async (): logsClient =>
  switch _client.contents {
  | Some(c) => c
  | None =>
    let sdk = await getSdk()
    let c = newClient(sdk.clientCtor)
    _client.contents = Some(c)
    c
  }

// ── Error classification ──────────────────────────────────────────────────────

@get @return(nullable) external exnName: JsExn.t => option<string> = "name"

let matchesAws = (jsErr: JsExn.t, code: string): bool =>
  switch (jsErr->exnName, JsExn.message(jsErr)) {
  | (Some(name), _) if name == code => true
  | (_, Some(msg)) => msg->String.includes(code)
  | _ => false
  }

/** The group is already there — the whole point of this provider. */
let isAlreadyExistsError = (jsErr: JsExn.t): bool =>
  jsErr->matchesAws("ResourceAlreadyExistsException")

/** The group is gone, so a delete or a retention/tag write is a no-op. */
let isAlreadyGoneError = (jsErr: JsExn.t): bool => jsErr->matchesAws("ResourceNotFoundException")

// CloudWatch Logs rejects concurrent writes against one group with
// `OperationAbortedException`, which plugin stacks deploying in parallel do hit.
let transientNames = [
  "OperationAbortedException",
  "ThrottlingException",
  "TooManyRequestsException",
  "ServiceUnavailableException",
]

let isRetryableError = (jsErr: JsExn.t): bool =>
  transientNames->Array.some(code => jsErr->matchesAws(code))

// ── Retry helper ─────────────────────────────────────────────────────────────

@val external setTimeout: (unit => unit, int) => int = "setTimeout"

/** Hand-rolled capped exponential backoff (`Effect` cannot be captured in a
    serialised provider closure). 1 s doubling to 8 s, 5 attempts — enough to
    outlast a concurrent write to the same group, and short enough that a real
    permission or quota failure is still reported promptly. */
let rec runWithRetry = async (
  ~attempt: int=0,
  ~maxAttempts: int=5,
  ~delayMs: int=1000,
  ~maxDelayMs: int=8000,
  makeCall: unit => promise<'a>,
): 'a =>
  try {
    await makeCall()
  } catch {
  | exn =>
    let jsExn = exn->JsExn.fromException
    let isRetryable = attempt < maxAttempts && jsExn->Option.mapOr(false, isRetryableError)
    if isRetryable {
      let _ = await Promise.make((resolve, _) => setTimeout(resolve, delayMs)->ignore)
      let nextDelay = delayMs * 2
      await runWithRetry(
        ~attempt=attempt + 1,
        ~maxAttempts,
        ~delayMs=nextDelay > maxDelayMs ? maxDelayMs : nextDelay,
        ~maxDelayMs,
        makeCall,
      )
    } else {
      switch jsExn {
      | Some(e) => rethrow(e)
      | None => throw(exn)
      }
    }
  }

// ── Provider input / output shapes ────────────────────────────────────────────

type providerInputs = {
  logGroupName: string,
  retentionInDays: int,
  tags: dict<string>,
}

// `managedBy` is this provider's own marker. State written by the classic
// `aws:cloudwatch/logGroup:LogGroup` resource that the alias adopts (see `make`)
// does not carry it, which is what tells `diff_` that the adopted state still
// has to be normalised — including Pulumi's own `__provider`, which only lands
// on a create or an update.
//
// Every field `diff_` reads must live here, and every one is nullable: adopted
// classic state carries a different shape, and a missing field must never read
// as a change.
type outs = {
  logGroupName: Nullable.t<string>,
  arn: Nullable.t<string>,
  retentionInDays: Nullable.t<int>,
  tags: Nullable.t<dict<string>>,
  managedBy: Nullable.t<string>,
}

type createResultOut = {id: string, outs: outs}
type updateResultOut = {outs: outs}
type diffResult = {changes: bool, replaces: array<string>, deleteBeforeReplace: bool}
type readResult = {id?: string, props?: outs}

let marker = "reventless:adopting-log-group"

// ── Steps ─────────────────────────────────────────────────────────────────────

/** DescribeLogGroups filtered by exact name. Returns `None` when the group does
    not exist. The prefix filter can match siblings, so the exact name is
    re-checked here rather than trusting the first row. */
let describe = async (~logGroupName: string): option<logGroupSummary> => {
  let sdk = await getSdk()
  let client = await getClient()
  let result = await runWithRetry(() =>
    client->sendDescribe(newCommand(sdk.describeCtor, {logGroupNamePrefix: logGroupName}))
  )
  result.logGroups
  ->Option.getOr([])
  ->Array.find(g => g.logGroupName == Some(logGroupName))
}

/** CloudWatch reports a group's ARN with a trailing `:*` (denoting its streams).
    `TagResource` rejects that spelling, so strip it. */
let taggableArn = (arn: string): string =>
  arn->String.endsWith(":*") ? arn->String.slice(~start=0, ~end=arn->String.length - 2) : arn

/** `0` means "never expire" and is a valid explicit opt-in, so it clears the
    policy rather than setting a retention of zero days. */
let applyRetention = async (~logGroupName: string, ~retentionInDays: int): unit => {
  let sdk = await getSdk()
  let client = await getClient()
  await runWithRetry(() =>
    retentionInDays > 0
      ? client->sendRetention(newCommand(sdk.retentionCtor, {logGroupName, retentionInDays}))
      : client->sendDeleteRetention(newCommand(sdk.deleteRetentionCtor, {logGroupName}))
  )
}

let applyTags = async (~arn: string, ~tags: dict<string>): unit => {
  let sdk = await getSdk()
  let client = await getClient()
  await runWithRetry(() =>
    client->sendTag(newCommand(sdk.tagCtor, {resourceArn: arn->taggableArn, tags}))
  )
}

// ── Provider methods ──────────────────────────────────────────────────────────

/** Create the group, or adopt the one that is already there. Both paths end
    with the declared retention and tags applied, which is what makes the
    outcome independent of who got there first. */
let create = async (inputs: providerInputs): createResultOut => {
  let sdk = await getSdk()
  let client = await getClient()
  let {logGroupName, retentionInDays, tags} = inputs

  let adopted = try {
    await runWithRetry(() =>
      client->sendCreate(newCommand(sdk.createCtor, {logGroupName, tags}))
    )
    false
  } catch {
  | exn if exn->JsExn.fromException->Option.mapOr(false, isAlreadyExistsError) => true
  }

  let arn = switch await describe(~logGroupName) {
  | Some({arn: ?Some(arn)}) => arn
  | _ =>
    JsError.throwWithMessage(
      `log group "${logGroupName}" is missing immediately after create/adopt`,
    )
  }

  if adopted {
    // CreateLogGroup carried the tags on the create path; the adopt path has to
    // put them on a group that already existed without them.
    await applyTags(~arn, ~tags)
    log.info(
      ~comp="Util_LogGroup_Adopting",
      `adopted existing log group "${logGroupName}"; applied retention ${retentionInDays->Int.toString}d and tags`,
    )
  }
  await applyRetention(~logGroupName, ~retentionInDays)

  {
    id: logGroupName,
    outs: {
      logGroupName: Nullable.make(logGroupName),
      arn: Nullable.make(arn),
      retentionInDays: Nullable.make(retentionInDays),
      tags: Nullable.make(tags),
      managedBy: Nullable.make(marker),
    },
  }
}

/** Re-apply retention and tags. Reached for a retention/tag change and for the
    first deploy after the alias migration, whose whole job is to normalise the
    adopted classic state. A name change replaces instead (see `diff_`), so the
    group being updated is always the one named in `news`. */
let update = async (_id: string, _olds: outs, news: providerInputs): updateResultOut => {
  let {logGroupName, retentionInDays, tags} = news
  let arn = switch await describe(~logGroupName) {
  | Some({arn: ?Some(arn)}) => Some(arn)
  | _ => None
  }
  switch arn {
  | Some(arn) =>
    await applyTags(~arn, ~tags)
    await applyRetention(~logGroupName, ~retentionInDays)
  | None =>
    // Drifted away underneath us — recreate rather than fail, since this
    // resource's contract is that the group ends up existing and configured.
    log.warn(
      ~comp="Util_LogGroup_Adopting",
      `log group "${logGroupName}" was gone at update; recreating it`,
    )
    let _ = await create(news)
  }
  {
    outs: {
      logGroupName: Nullable.make(logGroupName),
      arn: arn->Nullable.fromOption,
      retentionInDays: Nullable.make(retentionInDays),
      tags: Nullable.make(tags),
      managedBy: Nullable.make(marker),
    },
  }
}

let delete_ = async (id: string, _props: outs): unit => {
  let sdk = await getSdk()
  let client = await getClient()
  try {
    await runWithRetry(() => client->sendDelete(newCommand(sdk.deleteCtor, {logGroupName: id})))
  } catch {
  | exn if exn->JsExn.fromException->Option.mapOr(false, isAlreadyGoneError) => ()
  }
}

let sameTags = (a: dict<string>, b: dict<string>): bool => {
  let normalise = (d: dict<string>) => {
    let entries = d->Dict.toArray
    entries->Array.sort(((k1, _), (k2, _)) => String.compare(k1, k2))
    entries->Array.map(((k, v)) => `${k}=${v}`)->Array.join(" ")
  }
  normalise(a) == normalise(b)
}

/** The group name is the resource's identity — CloudWatch cannot rename a group
    in place, so a change replaces. Everything else is applied by `update`.

    State adopted from the classic resource carries no `managedBy`, and that
    alone counts as a change: the following update is what writes this provider's
    output shape (and Pulumi's `__provider`) into state. */
let diff_ = (_id: string, olds: outs, news: providerInputs): diffResult => {
  let replaces = switch olds.logGroupName->Nullable.toOption {
  | Some(oldName) if oldName != news.logGroupName => ["logGroupName"]
  | _ => []
  }
  let notNormalisedYet = olds.managedBy->Nullable.toOption->Option.isNone
  let retentionChanged = switch olds.retentionInDays->Nullable.toOption {
  | Some(days) => days != news.retentionInDays
  | None => false
  }
  let tagsChanged = switch olds.tags->Nullable.toOption {
  | Some(tags) => !sameTags(tags, news.tags)
  | None => false
  }
  {
    changes: replaces->Array.length > 0 || notNormalisedYet || retentionChanged || tagsChanged,
    replaces,
    // A replace means a different group name, so the new group can exist
    // alongside the old one and the old one's logs stay readable until it goes.
    deleteBeforeReplace: false,
  }
}

/** Live state for `pulumi refresh`. A group that is gone returns `{}` so Pulumi
    drops it from state and the next `up` recreates it. */
let read_ = async (id: string, props: outs): readResult =>
  switch await describe(~logGroupName=id) {
  | None =>
    log.info(~comp="Util_LogGroup_Adopting", `log group "${id}" is gone; reporting drift`)
    ({}: readResult)
  | Some(live) => {
      id,
      props: {
        ...props,
        logGroupName: Nullable.make(id),
        arn: live.arn->Nullable.fromOption,
        // Absent means "never expire", which is the `0` this provider accepts.
        retentionInDays: Nullable.make(live.retentionInDays->Option.getOr(0)),
      },
    }
  }

// Provider as a plain JS object — no Pulumi Output captures; all state flows
// through inputs / olds / news.
let provider = {
  "create": create,
  "update": update,
  "delete": delete_,
  "diff": diff_,
  "read": read_,
}

// ── Pulumi dynamic resource binding ──────────────────────────────────────────

/** Output shape matches `Cloudwatch.LogGroup.t` so consumers read `.name` /
    `.arn` / `.id` unchanged. */
type t = PulumiAws.Cloudwatch.LogGroup.t

type constructorProps = {
  logGroupName: Pulumi.Input.t<string>,
  retentionInDays: Pulumi.Input.t<int>,
  tags: Pulumi.Input.t<dict<string>>,
}

/** What is handed to `pulumi.dynamic.Resource`. The base constructor defines a
    resource property for every KEY of `props`, so an output-only field absent
    here never materialises on the resource and reads as a plain `undefined`
    instead of an Output. Declaring them `undefined` is Pulumi's documented way
    to register output-only properties; undefined values are dropped from the
    inputs RPC, so `create` still receives only the three real inputs. */
type resourceProps = {
  logGroupName: Pulumi.Input.t<string>,
  retentionInDays: Pulumi.Input.t<int>,
  tags: Pulumi.Input.t<dict<string>>,
  name: Nullable.t<string>,
  arn: Nullable.t<string>,
  managedBy: Nullable.t<string>,
}

let resourcePropsOf = (props: constructorProps): resourceProps => {
  logGroupName: props.logGroupName,
  retentionInDays: props.retentionInDays,
  tags: props.tags,
  name: Nullable.undefined,
  arn: Nullable.undefined,
  managedBy: Nullable.undefined,
}

// pulumi.dynamic.Resource constructor: (provider, name, props, opts). Explicit
// /index.js path because @pulumi/pulumi/dynamic is a directory import not
// resolvable in ESM mode.
@module("@pulumi/pulumi/dynamic/index.js") @new
external _newResource: ('provider, string, 'props, Pulumi.CustomResourceOptions.t) => t = "Resource"

/** Same call shape as `Cloudwatch.LogGroup.make`, so a site swaps over by
    changing the module name and passing `~logGroupName` instead of `name`.

    The alias adopts any group already in state as the classic
    `aws:cloudwatch/logGroup:LogGroup` resource, in place — without it, every
    already-managed group would be destroyed and recreated, losing its history
    for no reason. A dynamic provider's implementation changing does not itself
    force a replace, so the migration is a diff over the fields `diff_` reads. */
let make = (
  ~name: string,
  ~props: constructorProps,
  ~opts: option<Pulumi.CustomResourceOptions.t>,
): t => {
  let migrationAlias = Pulumi.Alias.make(~type_="aws:cloudwatch/logGroup:LogGroup", ~name, ())
  let finalOpts: Pulumi.CustomResourceOptions.t = switch opts {
  | Some(o) => {...o, aliases: [migrationAlias]}
  | None => {aliases: [migrationAlias]}
  }
  _newResource(provider, name, props->resourcePropsOf, finalOpts)
}
