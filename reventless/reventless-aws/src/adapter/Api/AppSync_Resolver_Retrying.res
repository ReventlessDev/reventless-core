/** AppSync resolver backed by a Pulumi dynamic provider that retries
    CreateResolver / UpdateResolver on the schema-propagation race:

      NotFoundException: No field named X found on type Query

    The `aws-native` Cloud Control handler does NOT internally wait for this
    propagation; neither does the classic provider. A custom dynamic provider
    that calls the AppSync SDK directly and retries with exponential backoff
    is the only reliable solution.

    Exposes the same `makeUnitJsResolver` / `makePipelineJsResolver` API as
    `AppSync_Resolver_Native` so `QueryDbResolvers_AppSync` only needs a
    one-line module swap.

    State migration: adds an alias pointing at the old
    `aws-native:appsync/resolver:Resolver` type so existing resources are
    adopted in-place on first deploy (no delete+recreate).

    See docs/plans/appsync-resolver-aws-native-retry.md. */

// ── AWS SDK bindings ─────────────────────────────────────────────────────────
//
// Pulumi dynamic providers serialise the provider object (and its captured
// closure of imports) into stack state. A static `@module("@aws-sdk/client-appsync")`
// binding pulls the SDK's transitive deps into that closure, and Pulumi's
// serialiser fails to resolve them at runtime (CJS/ESM dual-export confusion
// produces invalid module paths like
// `@aws-sdk/client-appsync/node_modules/@aws-sdk/region-config-resolver/dist-cjs/index.js`).
//
// Workaround: lazy-import the SDK at handler-invocation time via `dynImport`,
// so the SDK module is NOT part of the captured closure. Each provider method
// resolves the SDK on first use and caches an initialised client.

type appSyncClient

type sdkRuntime = {name: string, runtimeVersion: string}

let appsyncJsRuntime: sdkRuntime = {name: "APPSYNC_JS", runtimeVersion: "1.0.0"}

type sdkPipelineConfig = {functions: array<string>}

type sdkResolverInput = {
  apiId: string,
  typeName: string,
  fieldName: string,
  dataSourceName?: string,
  kind?: string,
  code?: string,
  runtime?: sdkRuntime,
  pipelineConfig?: sdkPipelineConfig,
}

type sdkResolverOutput = {resolverArn?: string}
type sdkResolverResult = {resolver?: sdkResolverOutput}

type createResolverCmd
type updateResolverCmd
type deleteResolverCmd
type getResolverCmd

type sdkDeleteInput = {apiId: string, typeName: string, fieldName: string}

// Shape of the dynamically-imported `@aws-sdk/client-appsync` module.
// Constructors are typed as `('arg) => 'class` so we can call them with `new`
// via a small JS interop helper.
type sdkModule = {
  @as("AppSyncClient") clientCtor: unit => appSyncClient,
  @as("CreateResolverCommand") createCtor: sdkResolverInput => createResolverCmd,
  @as("UpdateResolverCommand") updateCtor: sdkResolverInput => updateResolverCmd,
  @as("DeleteResolverCommand") deleteCtor: sdkDeleteInput => deleteResolverCmd,
  @as("GetResolverCommand") getCtor: sdkDeleteInput => getResolverCmd,
}

// Calls a constructor function with `new`. The SDK exports plain classes,
// so calling them as functions throws — we need `new`.
let newOf1: ('ctor, 'arg) => 'r = %raw(`(C, x) => new C(x)`)
let newOf0: 'ctor => 'r = %raw(`(C) => new C()`)

@send
external sendCreate: (appSyncClient, createResolverCmd) => promise<sdkResolverResult> = "send"
@send
external sendUpdate: (appSyncClient, updateResolverCmd) => promise<sdkResolverResult> = "send"
@send external sendDelete: (appSyncClient, deleteResolverCmd) => promise<unit> = "send"
@send external sendGet: (appSyncClient, getResolverCmd) => promise<sdkResolverResult> = "send"

// Dynamic ESM import — emitted by ReScript as a literal `import("...")`
// expression so the bundler does not statically capture the module.
@val external dynImport: string => promise<sdkModule> = "import"

// Lazy singletons — one SDK module + one client per deploy process.
let _sdk: ref<option<sdkModule>> = ref(None)
let _client: ref<option<appSyncClient>> = ref(None)

let getSdk = async (): sdkModule =>
  switch _sdk.contents {
  | Some(m) => m
  | None =>
    let m = await dynImport("@aws-sdk/client-appsync")
    _sdk.contents = Some(m)
    m
  }

let getClient = async (): appSyncClient =>
  switch _client.contents {
  | Some(c) => c
  | None =>
    let sdk = await getSdk()
    let c = newOf0(sdk.clientCtor)
    _client.contents = Some(c)
    c
  }

// ── Error classification ──────────────────────────────────────────────────────

@get @return(nullable) external exnName: JsExn.t => option<string> = "name"

/** Returns `true` iff the error is the AppSync schema-propagation race:
    `NotFoundException` with a message containing `"No field named"`.

    Critical: must NOT match the delete-path `"No resolver found"` 404 —
    those have the same exception name but a different message. */
let isFieldNotFoundError = (jsErr: JsExn.t): bool =>
  switch (jsErr->exnName, JsExn.message(jsErr)) {
  | (Some("NotFoundException"), Some(msg)) => msg->String.includes("No field named")
  | _ => false
  }

// ── Retry helper ─────────────────────────────────────────────────────────────
//
// Pulumi serialises the dynamic provider object (and its entire closure of
// captured references) into stack state. Anything reachable from the provider
// methods must be JS-serialisable. `Effect` (from the `effect` package)
// captures runtime-level state that fails Pulumi's `serializeFunction`, so
// the retry loop here is hand-rolled rather than `Effect.retry` + `Schedule`.
// See https://www.pulumi.com/docs/concepts/resources/dynamic-providers/ —
// "the entire closure of values captured by the provider is serialised".

@val external setTimeout: (unit => unit, int) => int = "setTimeout"

/** Hand-rolled retry on `NotFoundException / No field named` with capped
    exponential backoff:

    - Delay starts at 2 s, doubles each attempt, caps at 30 s.
    - Up to 6 attempts → ~2 min total budget.

    This is a **backstop**. The primary fix for the schema-propagation race
    is schema-push deduplication (see
    `docs/plans/appsync-schema-push-dedup.md`) — skipping
    `StartSchemaCreation` when the SDL is unchanged avoids restarting the
    propagation clock on no-op deploys, which is what turns a normally
    invisible race into a visible one.

    With dedup in place, this retry loop rarely fires. It is kept as a
    safety net for the genuine-schema-delta case (e.g. adding a new field
    or plugin), where propagation briefly blocks `CreateResolver` after a
    push. 2 minutes comfortably covers typical incremental deltas. If we
    ever see large multi-plugin renames in a single `pulumi up` exceed
    this budget, widening the cap is a tuning decision, not a
    redesign. */
let rec runWithRaceRetry = async (
  ~attempt: int=0,
  ~maxAttempts: int=6,
  ~delayMs: int=2000,
  ~maxDelayMs: int=30000,
  makeCall: unit => promise<'a>,
): 'a => {
  try {
    await makeCall()
  } catch {
  | exn =>
    let jsExn = exn->JsExn.fromException
    let name = jsExn->Option.flatMap(exnName)->Option.getOr("(no name)")
    let msg = jsExn->Option.flatMap(JsExn.message)->Option.getOr("(no message)")
    let isRetryable =
      attempt < maxAttempts && jsExn->Option.mapOr(false, isFieldNotFoundError)
    if isRetryable {
      Console.log(
        `[AppSync_Resolver_Retrying] retry ${attempt->Int.toString}/${maxAttempts->Int.toString} after ${delayMs->Int.toString}ms: ${name}: ${msg}`,
      )
      let _ = await Promise.make((resolve, _) => setTimeout(resolve, delayMs)->ignore)
      let nextDelay = delayMs * 2
      let cappedDelay = nextDelay > maxDelayMs ? maxDelayMs : nextDelay
      await runWithRaceRetry(
        ~attempt=attempt + 1,
        ~maxAttempts,
        ~delayMs=cappedDelay,
        ~maxDelayMs,
        makeCall,
      )
    } else {
      Console.log(
        `[AppSync_Resolver_Retrying] giving up after ${attempt->Int.toString} attempts: ${name}: ${msg}`,
      )
      throw(exn)
    }
  }
}

// ── Provider inputs (plain JS values delivered by Pulumi after resolution) ────

type providerInputs = {
  apiId: string,
  typeName: string,
  fieldName: string,
  dataSourceName?: string,
  kind: string,
  code: string,
  functions?: array<string>,
}

// ── SDK input builder ─────────────────────────────────────────────────────────

let buildSdkInput = (inputs: providerInputs): sdkResolverInput => {
  // Build the base required fields; then spread optional ones to keep
  // the SDK payload free of explicit `undefined` keys.
  let base: sdkResolverInput = {
    apiId: inputs.apiId,
    typeName: inputs.typeName,
    fieldName: inputs.fieldName,
    kind: inputs.kind,
    code: inputs.code,
    runtime: appsyncJsRuntime,
  }
  let withDs = switch inputs.dataSourceName {
  | Some(ds) => {...base, dataSourceName: ds}
  | None => base
  }
  switch inputs.functions {
  | Some(fns) => {...withDs, pipelineConfig: {functions: fns}}
  | None => withDs
  }
}

let extractArn = (resp: sdkResolverResult): string =>
  resp.resolver->Option.flatMap(r => r.resolverArn)->Option.getOr("unknown-arn")

// ── Dynamic provider method types ─────────────────────────────────────────────

// Include resolver coordinates in outs so that the delete handler can retrieve them
// even if the provider code is later re-serialised (Pulumi passes outs, not inputs, to delete).
type createOuts = {resolverArn: string, apiId: string, typeName: string, fieldName: string}
type createResult = {id: string, outs: createOuts}
type updateResult = {outs: createOuts}
type diffResult = {changes: bool, replaces: array<string>, deleteBeforeReplace: bool}
type readResult = {id: string, props: providerInputs}

// ── Provider methods ──────────────────────────────────────────────────────────

let create = async (inputs: providerInputs): createResult => {
  let sdk = await getSdk()
  let client = await getClient()
  let arn = await runWithRaceRetry(() =>
    client
    ->sendCreate(newOf1(sdk.createCtor, inputs->buildSdkInput))
    ->Promise.thenResolve(extractArn)
  )
  {id: arn, outs: {resolverArn: arn, apiId: inputs.apiId, typeName: inputs.typeName, fieldName: inputs.fieldName}}
}

let update = async (id: string, _olds: providerInputs, news: providerInputs): updateResult => {
  let sdk = await getSdk()
  let client = await getClient()
  let _ = await runWithRaceRetry(() =>
    client->sendUpdate(newOf1(sdk.updateCtor, news->buildSdkInput))
  )
  // ARN is stable across updates — preserve resolver coordinates in outs
  {outs: {resolverArn: id, apiId: news.apiId, typeName: news.typeName, fieldName: news.fieldName}}
}

/** Parse apiId, typeName, fieldName from the resolver ARN.
    ARN format: arn:aws:appsync:{region}:{account}:apis/{apiId}/types/{typeName}/resolvers/{fieldName}
    Pulumi dynamic providers pass OUTPUTS (not inputs) to delete, so props.apiId etc. may be
    undefined. The ARN passed as `id` is always available and contains all needed identifiers. */
let parseArn = (arn: string): option<sdkDeleteInput> => {
  let parts = arn->String.split("/")
  switch (parts->Array.get(1), parts->Array.get(3), parts->Array.get(5)) {
  | (Some(apiId), Some(typeName), Some(fieldName)) => Some({apiId, typeName, fieldName})
  | _ => None
  }
}

let delete_ = async (id: string, props: providerInputs): unit => {
  let sdk = await getSdk()
  let client = await getClient()
  // Prefer parsing from the ARN since Pulumi passes outputs (not inputs) to delete handlers.
  // Fall back to props fields for backward compat with older state that stores inputs in outs.
  let deleteInput: sdkDeleteInput = switch parseArn(id) {
  | Some(parsed) => parsed
  | None => {apiId: props.apiId, typeName: props.typeName, fieldName: props.fieldName}
  }
  await client->sendDelete(newOf1(sdk.deleteCtor, deleteInput))
}

/** Returns `true` for fields whose change requires delete+recreate.
    AppSync does not allow renaming the API, type, field, or kind in-place. */
let diff_ = (_id: string, olds: providerInputs, news: providerInputs): diffResult => {
  let replaces =
    [
      if olds.apiId != news.apiId {Some("apiId")} else {None},
      if olds.typeName != news.typeName {Some("typeName")} else {None},
      if olds.fieldName != news.fieldName {Some("fieldName")} else {None},
      if olds.kind != news.kind {Some("kind")} else {None},
    ]->Array.filterMap(x => x)
  let changes =
    replaces->Array.length > 0 ||
    olds.code != news.code ||
    olds.dataSourceName != news.dataSourceName ||
    olds.functions != news.functions
  {changes, replaces, deleteBeforeReplace: true}
}

// Minimal read — returns existing state unchanged.
// pulumi refresh does not need to detect AppSync resolver drift in practice.
let read_ = async (id: string, props: providerInputs): readResult => {id, props}

// Provider as a plain JS object (no Pulumi Output captures — all state via inputs/olds/news)
let provider = {
  "create": create,
  "update": update,
  "delete": delete_,
  "diff": diff_,
  "read": read_,
}

// ── Pulumi dynamic resource binding ──────────────────────────────────────────

/** Output shape is identical to AwsNative.AppSync.Resolver.t so
    `Util.AppSync.toResourceNative` works without modification. */
type t = PulumiAws.AwsNative.AppSync.Resolver.t

type constructorProps = {
  apiId: Pulumi.Input.t<string>,
  typeName: Pulumi.Input.t<string>,
  fieldName: Pulumi.Input.t<string>,
  dataSourceName?: Pulumi.Input.t<string>,
  kind: Pulumi.Input.t<string>,
  code: Pulumi.Input.t<string>,
  functions?: Pulumi.Input.t<array<string>>,
}

// pulumi.dynamic.Resource constructor: (provider, name, props, opts)
// Use the explicit /index.js path because @pulumi/pulumi/dynamic is a
// directory import not resolvable in ESM mode.
@module("@pulumi/pulumi/dynamic/index.js") @new
external _newResource: ('provider, string, 'props, Pulumi.CustomResourceOptions.t) => t =
  "Resource"

let makeResolver = (
  ~name: string,
  ~props: constructorProps,
  ~opts: option<Pulumi.CustomResourceOptions.t>,
): t => {
  // Always include an alias for the aws-native resource previously in state —
  // prevents delete+recreate on first deploy (in-place adoption).
  let migrationAlias = Pulumi.Alias.make(
    ~type_="aws-native:appsync/resolver:Resolver",
    ~name,
    (),
  )
  let finalOpts: Pulumi.CustomResourceOptions.t = switch opts {
  | Some(o) => {...o, aliases: [migrationAlias]}
  | None => {aliases: [migrationAlias]}
  }
  _newResource(provider, name, props, finalOpts)
}

// ── Public API (identical signatures to AppSync_Resolver_Native) ──────────────

module Functions = PulumiAws.AppSync.Resolver.Functions

let makeUnitJsResolver = (
  ~name,
  ~api: Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>,
  ~dataSourceName,
  ~type_,
  ~field,
  ~code,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) =>
  makeResolver(
    ~name,
    ~props={
      apiId: api->Pulumi.Output.flatMap(a => a.id)->Pulumi.Output.asInput,
      typeName: type_,
      fieldName: field,
      dataSourceName: dataSourceName,
      kind: "UNIT"->Pulumi.Input.make,
      code,
    },
    ~opts,
  )

let makePipelineJsResolver = (
  ~name,
  ~api: Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>,
  ~type_,
  ~field,
  ~code,
  ~functions: array<PulumiAws.AppSync.Function.t>,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) =>
  makeResolver(
    ~name,
    ~props={
      apiId: api->Pulumi.Output.flatMap(a => a.id)->Pulumi.Output.asInput,
      typeName: type_,
      fieldName: field,
      kind: "PIPELINE"->Pulumi.Input.make,
      code,
      functions: functions->Array.map(f => f.functionId)->Pulumi.Output.all->Pulumi.Output.asInput,
    },
    ~opts,
  )
