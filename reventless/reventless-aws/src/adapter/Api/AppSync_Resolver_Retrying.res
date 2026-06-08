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

let log = ReventlessCore.Logger.fromEnv()

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

/** Returns `true` iff a delete should be treated as a no-op because the
    target resource no longer exists in AWS.  Covers three cases:

    - `"API not found."` — the AppSync API itself was already deleted (e.g.
      manually in the console or by a prior teardown); the resolver cannot
      exist without its parent API.
    - `"No resolver found"` — the API exists but the resolver was already
      removed (diverged Pulumi state).
    - `"Type not found"` — the parent GraphQL type was dropped from the schema
      (e.g. a plugin's schema fragment was lost during a runtime re-stitch),
      taking every field-attached resolver with it; resolver absent is the
      desired end-state, so `refresh` should report drift and a subsequent
      `up` will recreate against the restored schema.

    In all cases the desired end-state (resolver absent) is already reached,
    so the Pulumi delete should succeed. */
let isAlreadyDeletedError = (jsErr: JsExn.t): bool =>
  switch (jsErr->exnName, JsExn.message(jsErr)) {
  | (Some("NotFoundException"), Some(msg)) =>
    msg->String.includes("API not found") ||
    msg->String.includes("No resolver found") ||
    msg->String.includes("Type not found")
  | _ => false
  }

/** Returns `true` iff AppSync rejected the create because a resolver for that
    field already exists (Pulumi state / AppSync divergence). */
let isAlreadyExistsError = (jsErr: JsExn.t): bool =>
  switch (jsErr->exnName, JsExn.message(jsErr)) {
  | (Some("BadRequestException"), Some(msg)) => msg->String.includes("Only one resolver is allowed")
  | _ => false
  }

/** Returns `true` iff AppSync rejected the mutation because the API-level
    schema-creation lock is held by an in-flight `StartSchemaCreation`:
    `ConcurrentModificationException` with message
    `"Schema is currently being altered"`.

    AppSync holds a single per-API lock during schema creation and rejects any
    concurrent `CreateResolver` / `UpdateResolver` (and `CreateDataSource`,
    `CreateFunction`) until the schema reaches ACTIVE. Plugin_Builder gates
    resolver creation on the plugin schema push, but admin-side resolvers in
    `Platform_Admin.construct` are created synchronously and race the platform
    schema push initiated from `Platform.res`. */
let isSchemaAlteringError = (jsErr: JsExn.t): bool =>
  switch (jsErr->exnName, JsExn.message(jsErr)) {
  | (Some("ConcurrentModificationException"), Some(msg)) =>
    msg->String.includes("Schema is currently being altered")
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

/** Throws a JavaScript exception directly (bypasses the ReScript exn wrapper). */
let jsThrow: JsExn.t => 'a = %raw(`e => { throw e }`)

/** Hand-rolled retry on two transient AppSync races with capped exponential
    backoff:

    - `NotFoundException / No field named` — schema-propagation race after a
      successful `StartSchemaCreation`. Backstop for the per-plugin dedup
      flow (see `docs/plans/appsync-schema-push-dedup.md`).
    - `ConcurrentModificationException / Schema is currently being altered` —
      API-level lock contention with an in-flight `StartSchemaCreation` on
      the same API (admin resolvers racing the platform schema push from
      `Platform.res`).

    Backoff: delay starts at 2 s, doubles each attempt, caps at 30 s. Up to
    8 attempts → ~150 s total budget — generous enough to outlast a typical
    admin schema push (`waitForSchemaActive` polls 30 × 500 ms = 15 s and
    real propagation usually finishes well inside that). The cap doubles as
    a coarse fairness bound: if a schema push is genuinely taking > 2 min,
    failing loud is better than retrying forever.

    This is a **backstop**. The architectural fix for the
    `ConcurrentModificationException` case is to gate
    `Platform_Admin.construct`'s `createResolvers` on the admin schema push,
    mirroring what Plugin_Builder does with `schemaPushed`. */
let rec runWithRaceRetry = async (
  ~attempt: int=0,
  ~maxAttempts: int=8,
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
      attempt < maxAttempts &&
      jsExn->Option.mapOr(false, e => isFieldNotFoundError(e) || isSchemaAlteringError(e))
    if isRetryable {
      log.info(
        ~comp="AppSync_Resolver_Retrying",
        `attempt ${(attempt + 1)->Int.toString}/${maxAttempts->Int.toString} failed, retrying in ${delayMs->Int.toString}ms: ${name}: ${msg}`,
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
      // Only log when we exhausted retries on a retryable error — not on the
      // first non-retryable failure, which the caller may handle itself.
      if attempt > 0 {
        log.warn(
          ~comp="AppSync_Resolver_Retrying",
          `giving up after ${(attempt + 1)->Int.toString} attempts: ${name}: ${msg}`,
        )
      }
      // Re-throw the original JavaScript error so Pulumi can display its message.
      // throw(exn) would rethrow the ReScript exception wrapper (RE_EXN_ID), which
      // has no `.message` property and causes Pulumi to display "error: undefined".
      switch jsExn {
      | Some(e) => jsThrow(e)
      | None => throw(exn)
      }
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

// Pulumi passes OUTPUTS (not inputs) to diff/delete/update handlers, so all fields
// that diff_ compares must be stored in createOuts/updateResult.outs, otherwise
// olds.fieldX is undefined at diff time and `undefined != newValue` is always true
// in JavaScript — causing every deploy to trigger a delete+recreate.
type createOuts = {
  resolverArn: string,
  apiId: string,
  typeName: string,
  fieldName: string,
  kind: string,
  code: string,
  dataSourceName?: string,
  functions?: array<string>,
}
type createResult = {id: string, outs: createOuts}
type updateResult = {outs: createOuts}
type diffResult = {changes: bool, replaces: array<string>, deleteBeforeReplace: bool}
// Optional fields so `read_` can return `{}` when the resolver no longer exists
// in AppSync — Pulumi treats an empty `ReadResult` as "resource gone", removes
// it from state on `pulumi refresh`, and re-creates it on the next `pulumi up`.
type readResult = {id?: string, props?: providerInputs}

// ── Provider methods ──────────────────────────────────────────────────────────

let makeOuts = (resolverArn: string, inputs: providerInputs): createOuts => {
  let base: createOuts = {
    resolverArn,
    apiId: inputs.apiId,
    typeName: inputs.typeName,
    fieldName: inputs.fieldName,
    kind: inputs.kind,
    code: inputs.code,
  }
  let withDs = switch inputs.dataSourceName {
  | Some(ds) => {...base, dataSourceName: ds}
  | None => base
  }
  switch inputs.functions {
  | Some(fns) => {...withDs, functions: fns}
  | None => withDs
  }
}

let create = async (inputs: providerInputs): createResult => {
  let sdk = await getSdk()
  let client = await getClient()
  let arn =
    try {
      await runWithRaceRetry(() =>
        client
        ->sendCreate(newOf1(sdk.createCtor, inputs->buildSdkInput))
        ->Promise.thenResolve(extractArn)
      )
    } catch {
    | exn =>
      // If the resolver already exists (AppSync / Pulumi state divergence from a
      // previous partial deploy), update it to match desired config and adopt its ARN.
      // This makes create idempotent and lets stuck stacks recover without manual intervention.
      let handled =
        exn->JsExn.fromException->Option.mapOr(false, isAlreadyExistsError)
      if handled {
        let resp = await client->sendUpdate(newOf1(sdk.updateCtor, inputs->buildSdkInput))
        extractArn(resp)
      } else {
        let jsExn = exn->JsExn.fromException
        switch jsExn {
        | Some(e) => jsThrow(e)
        | None => throw(exn)
        }
      }
    }
  {id: arn, outs: makeOuts(arn, inputs)}
}

let update = async (id: string, _olds: providerInputs, news: providerInputs): updateResult => {
  let sdk = await getSdk()
  let client = await getClient()
  let arn =
    try {
      let _ = await runWithRaceRetry(() =>
        client->sendUpdate(newOf1(sdk.updateCtor, news->buildSdkInput))
      )
      // ARN is stable across updates — reuse the existing id
      id
    } catch {
    | exn =>
      // If the resolver was deleted from AppSync (e.g. by a schema replacement),
      // fall back to CreateResolver so the resource is transparently recreated.
      let handled =
        exn->JsExn.fromException->Option.mapOr(false, isAlreadyDeletedError)
      if handled {
        let resp = await runWithRaceRetry(() =>
          client
          ->sendCreate(newOf1(sdk.createCtor, news->buildSdkInput))
          ->Promise.thenResolve(extractArn)
        )
        resp
      } else {
        let jsExn = exn->JsExn.fromException
        switch jsExn {
        | Some(e) => jsThrow(e)
        | None => throw(exn)
        }
      }
    }
  {outs: makeOuts(arn, news)}
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
  try {
    await client->sendDelete(newOf1(sdk.deleteCtor, deleteInput))
  } catch {
  | exn if exn->JsExn.fromException->Option.mapOr(false, isAlreadyDeletedError) => ()
  }
}

// Guard against undefined in olds for resources created with older code that did not
// store all fields in createOuts. In JavaScript `undefined !== value` evaluates to
// true, which would incorrectly flag every such field as requiring replacement.
let isDefined: string => bool = %raw(`x => x !== undefined && x !== null`)

/** Returns `true` for fields whose change requires delete+recreate.
    AppSync does not allow renaming the API, type, field, or kind in-place. */
let diff_ = (_id: string, olds: providerInputs, news: providerInputs): diffResult => {
  let replaces =
    [
      if isDefined(olds.apiId) && olds.apiId != news.apiId {Some("apiId")} else {None},
      if isDefined(olds.typeName) && olds.typeName != news.typeName {Some("typeName")} else {None},
      if isDefined(olds.fieldName) && olds.fieldName != news.fieldName {Some("fieldName")} else {None},
      if isDefined(olds.kind) && olds.kind != news.kind {Some("kind")} else {None},
    ]->Array.filterMap(x => x)
  // For in-place update detection (non-replace changes): compare as-is.
  // If olds is from old state (missing fields), this may trigger an unnecessary
  // update, but that is safe — the update simply re-applies the resolver.
  let changes =
    replaces->Array.length > 0 ||
    olds.code != news.code ||
    olds.dataSourceName != news.dataSourceName ||
    olds.functions != news.functions
  {changes, replaces, deleteBeforeReplace: true}
}

/** Read live state for `pulumi refresh`.

    Calls `GetResolver` against AppSync. If the resolver exists, returns the
    stored inputs unchanged so Pulumi keeps the resource in state. If AppSync
    reports the resolver as missing (`NotFoundException / No resolver found`
    or `API not found.`), returns `{}` to signal drift — Pulumi removes the
    resource from state on `pulumi refresh` and the next `pulumi up` recreates
    it via `create`.

    Healing flow: `pulumi refresh && pulumi up` after a schema replacement
    that silently drops resolvers in AppSync. Without the live check the
    `update` AlreadyDeleted→Create fallback only fires when an input field
    changes; refresh alone could not detect the drift. */
let read_ = async (id: string, props: providerInputs): readResult => {
  let sdk = await getSdk()
  let client = await getClient()
  // Prefer parsing the ARN since Pulumi passes outputs (not inputs) to read
  // handlers; fall back to props fields for older state.
  let getInput: sdkDeleteInput = switch parseArn(id) {
  | Some(parsed) => parsed
  | None => {apiId: props.apiId, typeName: props.typeName, fieldName: props.fieldName}
  }
  try {
    let _ = await client->sendGet(newOf1(sdk.getCtor, getInput))
    {id, props}
  } catch {
  | exn if exn->JsExn.fromException->Option.mapOr(false, isAlreadyDeletedError) =>
    log.info(
      ~comp="AppSync_Resolver_Retrying",
      `resolver ${getInput.typeName}.${getInput.fieldName} missing in AppSync; reporting drift`,
    )
    ({}: readResult)
  | exn =>
    // Propagate non-404 errors (network/auth) so refresh fails loudly rather
    // than silently dropping the resource from state.
    let jsExn = exn->JsExn.fromException
    switch jsExn {
    | Some(e) => jsThrow(e)
    | None => throw(exn)
    }
  }
}

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

let makeSubscriptionResolverCode = (~filter: option<string>): string =>
  switch filter {
  | None => `export function request(ctx) {
  return { payload: null };
}

export function response(ctx) {
  return ctx.result;
}`
  | Some(f) => `export function request(ctx) {
  extensions.setSubscriptionFilter(${f});
  return {};
}

export function response(ctx) {
  return ctx.result;
}`
}

let makeSubscriptionResolver = (
  ~name,
  ~api: Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>,
  ~field,
  ~dataSourceName: option<Pulumi.Input.t<string>>=?,
  ~subscriptionFilter: option<string>=?,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) => {
  let baseProps: constructorProps = {
    apiId: api->Pulumi.Output.flatMap(a => a.id)->Pulumi.Output.asInput,
    typeName: "Subscription"->Pulumi.Input.make,
    fieldName: field->Pulumi.Input.make,
    kind: "UNIT"->Pulumi.Input.make,
    code: makeSubscriptionResolverCode(~filter=subscriptionFilter)->Pulumi.Input.make,
  }
  let props = switch dataSourceName {
  | Some(ds) => {...baseProps, dataSourceName: ds}
  | None => baseProps
  }
  makeResolver(~name, ~props, ~opts)
}

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
