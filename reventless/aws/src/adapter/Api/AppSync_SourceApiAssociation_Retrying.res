/** AppSync SourceApiAssociation backed by a Pulumi dynamic provider that
    retries CreateSourceApiAssociation (and Delete) on the per-merged-API
    concurrency race:

      ConcurrentModificationException (HTTP 409)

    AWS serializes association writes per merged API. When plugin stacks deploy
    in parallel, their first-time associations against the *same* merged API
    race and 409 — the classic `aws:appsync/sourceApiAssociation` provider does
    NOT retry this, so the losing stack's `pulumi up` fails. This provider owns
    the Create / Delete / Get SDK calls and retries the 409 (plus sibling
    transient AWS errors) with capped exponential backoff. It is the Phase-4
    fix that lets plugin deploys run concurrently again without a CI-level
    `max-parallel: 1` serialization (docs/plans/done/merged-api-push-free-composition.md,
    "Association creation 409s under concurrency").

    Steady-state is unaffected: under AUTO_MERGE, AWS re-merges automatically on
    every source-API schema change with no further association calls, so the
    409 is a creation/deletion-time race only.

    The initial merge is asynchronous (AUTO_MERGE schedules it); this provider
    returns as soon as the association record exists. Waiting for MERGE_SUCCESS
    stays the caller's job via `AppSync_MergedApi.mergeStatusGateWith`, so a
    failed merge still fails the deploy loudly.

    State migration: aliases the classic
    `aws:appsync/sourceApiAssociation:SourceApiAssociation` type so existing
    associations are adopted in-place on first deploy (no delete+recreate → no
    merge blip on the shared endpoint).

    Mirrors `AppSync_Resolver_Retrying`'s dynImport + hand-rolled-retry shape:
    Pulumi serialises the dynamic provider's whole captured closure into stack
    state, and `Effect` (used by the in-process `AppSync_Error` retry) fails
    that serialisation, so the SDK is lazily imported and the backoff loop is
    hand-rolled here. */

let log = ReventlessCore.Logger.fromEnv()

// ── AWS SDK bindings (lazily imported — see AppSync_Resolver_Retrying) ─────────

type appSyncClient

type mergeConfig = {mergeType: string}

type createInput = {
  mergedApiIdentifier: string,
  sourceApiIdentifier: string,
  sourceApiAssociationConfig?: mergeConfig,
}

type assocSummary = {
  associationId?: string,
  associationArn?: string,
}
type createResult = {sourceApiAssociation?: assocSummary}
type getResult = {sourceApiAssociation?: assocSummary}

type idInput = {associationId: string, mergedApiIdentifier: string}

type createCmd
type getCmd
type deleteCmd

// Shape of the dynamically-imported `@aws-sdk/client-appsync` module. Only the
// three association commands are needed here.
type sdkModule = {
  @as("AppSyncClient") clientCtor: unit => appSyncClient,
  @as("CreateSourceApiAssociationCommand") createCtor: createInput => createCmd,
  @as("GetSourceApiAssociationCommand") getCtor: idInput => getCmd,
  @as("DeleteSourceApiAssociationCommand") deleteCtor: idInput => deleteCmd,
}

// Calls a constructor with `new` — the SDK exports plain classes.
let newOf1: ('ctor, 'arg) => 'r = %raw(`(C, x) => new C(x)`)
let newOf0: 'ctor => 'r = %raw(`(C) => new C()`)

@send external sendCreate: (appSyncClient, createCmd) => promise<createResult> = "send"
@send external sendGet: (appSyncClient, getCmd) => promise<getResult> = "send"
@send external sendDelete: (appSyncClient, deleteCmd) => promise<unit> = "send"

// Dynamic ESM import — emitted as a literal `import("...")` so the bundler /
// Pulumi serialiser does not statically capture the module in the closure.
@val external dynImport: string => promise<sdkModule> = "import"

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

// Transient AWS errors worth retrying — the same set `AppSync_Error.classify`
// treats as Transient, matched here by exception name OR message (the SDK
// surfaces the code in either depending on the error path).
let transientNames = [
  "ConcurrentModificationException",
  "ThrottlingException",
  "TooManyRequestsException",
  "InternalFailureException",
  "ServiceUnavailableException",
  "ServiceUnavailable",
]

/** Returns `true` iff the error is the per-merged-API association concurrency
    race: `ConcurrentModificationException` (HTTP 409). Exposed for testing. */
let isConcurrentModificationError = (jsErr: JsExn.t): bool =>
  switch (jsErr->exnName, JsExn.message(jsErr)) {
  | (Some("ConcurrentModificationException"), _) => true
  | (_, Some(msg)) => msg->String.includes("ConcurrentModificationException")
  | _ => false
  }

/** Returns `true` for any transient AWS error the create/delete loop should
    retry (the 409 race plus throttling / transient service errors). */
let isRetryableAssociationError = (jsErr: JsExn.t): bool =>
  switch (jsErr->exnName, JsExn.message(jsErr)) {
  | (Some(name), _) if transientNames->Array.includes(name) => true
  | (_, Some(msg)) => transientNames->Array.some(n => msg->String.includes(n))
  | _ => false
  }

/** Returns `true` iff the target association is already gone, so a delete /
    read should be treated as a no-op / drift. AWS reports a missing merged API
    or association as `NotFoundException`. */
let isAlreadyGoneError = (jsErr: JsExn.t): bool =>
  switch (jsErr->exnName, JsExn.message(jsErr)) {
  | (Some("NotFoundException"), _) => true
  | (_, Some(msg)) => msg->String.includes("NotFoundException") || msg->String.includes("not found")
  | _ => false
  }

// ── Retry helper ─────────────────────────────────────────────────────────────

@val external setTimeout: (unit => unit, int) => int = "setTimeout"

/** Throws a JavaScript exception directly (bypasses the ReScript exn wrapper),
    so Pulumi displays AWS's real message rather than "error: undefined". */
let jsThrow: JsExn.t => 'a = %raw(`e => { throw e }`)

/** Hand-rolled retry on the transient AppSync association races with capped
    exponential backoff. Delay starts at 2 s, doubles each attempt, caps at
    30 s; up to 8 attempts → ~150 s budget — enough to outlast several serial
    per-merged-API merges (each ~12 s, spike-measured) when a handful of plugin
    stacks associate against one merged API at once. Beyond that, failing loud
    beats retrying forever. */
let rec runWithRetry = async (
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
      jsExn->Option.mapOr(false, isRetryableAssociationError)
    if isRetryable {
      log.info(
        ~comp="AppSync_SourceApiAssociation_Retrying",
        `attempt ${(attempt + 1)->Int.toString}/${maxAttempts->Int.toString} failed, retrying in ${delayMs->Int.toString}ms: ${name}: ${msg}`,
      )
      let _ = await Promise.make((resolve, _) => setTimeout(resolve, delayMs)->ignore)
      let nextDelay = delayMs * 2
      let cappedDelay = nextDelay > maxDelayMs ? maxDelayMs : nextDelay
      await runWithRetry(~attempt=attempt + 1, ~maxAttempts, ~delayMs=cappedDelay, ~maxDelayMs, makeCall)
    } else {
      if attempt > 0 {
        log.warn(
          ~comp="AppSync_SourceApiAssociation_Retrying",
          `giving up after ${(attempt + 1)->Int.toString} attempts: ${name}: ${msg}`,
        )
      }
      switch jsExn {
      | Some(e) => jsThrow(e)
      | None => throw(exn)
      }
    }
  }
}

// ── Identifier extraction ─────────────────────────────────────────────────────
//
// Pulumi passes OUTPUTS (not inputs) to delete/read handlers, and an adopted
// classic resource carries a different output shape than this provider writes.
// The resource `id` is always present, so derive (mergedApiId, associationId)
// from it, falling back to stored props for older/mixed state.
//
//   - this provider's own id  = the association ARN:
//       arn:aws:appsync:<region>:<acct>:apis/<mergedApiId>/sourceApiAssociations/<assocId>
//   - the classic provider's id = "<mergedApiId>,<assocId>"

let idsFromArn = (arn: string): option<idInput> => {
  let parts = arn->String.split("/")
  let idx = parts->Array.indexOf("sourceApiAssociations")
  switch (idx >= 1, parts->Array.get(idx - 1), parts->Array.get(idx + 1)) {
  | (true, Some(mergedApiId), Some(assocId)) =>
    Some({mergedApiIdentifier: mergedApiId, associationId: assocId})
  | _ => None
  }
}

let idsFromComposite = (id: string): option<idInput> =>
  switch id->String.split(",") {
  | [mergedApiId, assocId] => Some({mergedApiIdentifier: mergedApiId, associationId: assocId})
  | _ => None
  }

// ── Provider input / output shapes ────────────────────────────────────────────

type providerInputs = {
  mergedApiIdentifier: string,
  sourceApiIdentifier: string,
  mergeType: string,
}

// `arn` / `associationId` are named to match PulumiAws.AppSync.SourceApiAssociation.t
// so consumers (mergeStatusGateWith) read `.associationId` unchanged. All fields
// diff_ compares must live here or `olds.field` is undefined at diff time.
type createOuts = {
  arn: string,
  associationId: string,
  mergedApiIdentifier: string,
  sourceApiIdentifier: string,
  mergeType: string,
}
type createResultOut = {id: string, outs: createOuts}
type updateResultOut = {outs: createOuts}
type diffResult = {changes: bool, replaces: array<string>, deleteBeforeReplace: bool}
type readResult = {id?: string, props?: createOuts}

// Extract from stored outs OR classic-shaped props via the id, so delete/read
// work for both this provider's resources and freshly-adopted classic ones.
let identifiersFrom = (~id: string, ~props: createOuts): option<idInput> =>
  switch idsFromArn(id) {
  | Some(ids) => Some(ids)
  | None =>
    switch idsFromComposite(id) {
    | Some(ids) => Some(ids)
    | None =>
      // Last resort: this provider's own stored outs.
      switch idsFromArn(props.arn) {
      | Some(ids) => Some(ids)
      | None => None
      }
    }
  }

// ── Provider methods ──────────────────────────────────────────────────────────

let extractIds = (resp: createResult): (string, string) =>
  switch resp.sourceApiAssociation {
  | Some({associationArn: ?Some(arn), associationId: ?Some(aid)}) => (arn, aid)
  | _ =>
    JsError.throwWithMessage(
      "CreateSourceApiAssociation returned no associationArn / associationId",
    )
  }

let create = async (inputs: providerInputs): createResultOut => {
  let sdk = await getSdk()
  let client = await getClient()
  let (arn, associationId) = await runWithRetry(() =>
    client
    ->sendCreate(
      newOf1(
        sdk.createCtor,
        {
          mergedApiIdentifier: inputs.mergedApiIdentifier,
          sourceApiIdentifier: inputs.sourceApiIdentifier,
          sourceApiAssociationConfig: {mergeType: inputs.mergeType},
        },
      ),
    )
    ->Promise.thenResolve(extractIds)
  )
  {
    id: arn,
    outs: {
      arn,
      associationId,
      mergedApiIdentifier: inputs.mergedApiIdentifier,
      sourceApiIdentifier: inputs.sourceApiIdentifier,
      mergeType: inputs.mergeType,
    },
  }
}

// No in-place mutation path: identity changes force replace (see diff_), and
// AUTO_MERGE re-merges are automatic, so update is only ever reached for a
// no-op reconcile — return the stored outs unchanged.
let update = async (_id: string, olds: createOuts, _news: providerInputs): updateResultOut => {
  {outs: olds}
}

let delete_ = async (id: string, props: createOuts): unit => {
  let sdk = await getSdk()
  let client = await getClient()
  switch identifiersFrom(~id, ~props) {
  | None =>
    log.warn(
      ~comp="AppSync_SourceApiAssociation_Retrying",
      `delete: could not derive association identifiers from id "${id}"; treating as already gone`,
    )
  | Some(ids) =>
    try {
      await runWithRetry(() => client->sendDelete(newOf1(sdk.deleteCtor, ids)))
    } catch {
    | exn if exn->JsExn.fromException->Option.mapOr(false, isAlreadyGoneError) => ()
    }
  }
}

let isDefined: string => bool = %raw(`x => x !== undefined && x !== null`)

/** Identity fields force replace — AWS cannot re-point an association's merged
    API or source API in place. Guard undefined olds (adopted classic state)
    so a missing field never spuriously flags a replace. */
let diff_ = (_id: string, olds: createOuts, news: providerInputs): diffResult => {
  let replaces =
    [
      isDefined(olds.mergedApiIdentifier) && olds.mergedApiIdentifier != news.mergedApiIdentifier
        ? Some("mergedApiIdentifier")
        : None,
      isDefined(olds.sourceApiIdentifier) && olds.sourceApiIdentifier != news.sourceApiIdentifier
        ? Some("sourceApiIdentifier")
        : None,
      isDefined(olds.mergeType) && olds.mergeType != news.mergeType ? Some("mergeType") : None,
    ]->Array.filterMap(x => x)
  // createBeforeDelete: a replace only ever fires on an identity change → a
  // different (mergedApi, sourceApi) pair, so the new association can be made
  // before the old is torn down without a duplicate-pair rejection.
  {changes: replaces->Array.length > 0, replaces, deleteBeforeReplace: false}
}

/** Read live state for `pulumi refresh`: GetSourceApiAssociation. Missing
    (association or merged API gone) → return `{}` so Pulumi drops it from state
    and the next `up` recreates it; other errors propagate so refresh fails
    loudly rather than silently discarding the resource. */
let read_ = async (id: string, props: createOuts): readResult => {
  let sdk = await getSdk()
  let client = await getClient()
  switch identifiersFrom(~id, ~props) {
  | None => ({}: readResult)
  | Some(ids) =>
    try {
      let _ = await client->sendGet(newOf1(sdk.getCtor, ids))
      {id, props}
    } catch {
    | exn if exn->JsExn.fromException->Option.mapOr(false, isAlreadyGoneError) =>
      log.info(
        ~comp="AppSync_SourceApiAssociation_Retrying",
        `association ${ids.associationId} on ${ids.mergedApiIdentifier} missing in AppSync; reporting drift`,
      )
      ({}: readResult)
    | exn =>
      let jsExn = exn->JsExn.fromException
      switch jsExn {
      | Some(e) => jsThrow(e)
      | None => throw(exn)
      }
    }
  }
}

// Provider as a plain JS object (no Pulumi Output captures — all state flows
// through inputs / olds / news).
let provider = {
  "create": create,
  "update": update,
  "delete": delete_,
  "diff": diff_,
  "read": read_,
}

// ── Pulumi dynamic resource binding ──────────────────────────────────────────

/** Output shape is identical to PulumiAws.AppSync.SourceApiAssociation.t so
    `AppSync_MergedApi.associateSourceWithMergedArn` and `mergeStatusGateWith`
    consume `.id` / `.arn` / `.associationId` unchanged. */
type t = PulumiAws.AppSync.SourceApiAssociation.t

type constructorProps = {
  mergedApiIdentifier: Pulumi.Input.t<string>,
  sourceApiIdentifier: Pulumi.Input.t<string>,
  mergeType: Pulumi.Input.t<string>,
}

// pulumi.dynamic.Resource constructor: (provider, name, props, opts). Explicit
// /index.js path because @pulumi/pulumi/dynamic is a directory import not
// resolvable in ESM mode.
@module("@pulumi/pulumi/dynamic/index.js") @new
external _newResource: ('provider, string, 'props, Pulumi.CustomResourceOptions.t) => t = "Resource"

let make = (
  ~name: string,
  ~props: constructorProps,
  ~opts: option<Pulumi.CustomResourceOptions.t>,
): t => {
  // Adopt the classic aws resource previously in state in-place (no
  // delete+recreate → no merge blip on the shared merged endpoint).
  let migrationAlias = Pulumi.Alias.make(
    ~type_="aws:appsync/sourceApiAssociation:SourceApiAssociation",
    ~name,
    (),
  )
  let finalOpts: Pulumi.CustomResourceOptions.t = switch opts {
  | Some(o) => {...o, aliases: [migrationAlias]}
  | None => {aliases: [migrationAlias]}
  }
  _newResource(provider, name, props, finalOpts)
}
