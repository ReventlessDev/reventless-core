/** Attaches the pre-token-generation trigger to a Cognito user pool the stack
    does **not** own — the BYO case of `Platform_Stack.resolveCognitoUserPool`,
    where `platform:cognitoUserPoolId` names an existing pool that is looked up
    for its ARN and nothing more.

    BYO cannot be the unsupported mode. It is the mode a customer with an
    existing identity estate is in, and requiring the framework to own their user
    pool before an operator can act as a role is a far larger ask than the
    feature is worth. In **auto** mode the pool is ours and
    `lambdaConfig.preTokenGeneration` is an ordinary property on a resource we
    already declare — this resource is not used there.

    The trigger is a property of the pool and Cognito offers no separate
    attachment resource, so something has to call `UpdateUserPool` against a pool
    no stack owns. That belongs in a declared resource executed at deploy time,
    never a hand-run command against a live pool, which would leave the
    deployment's behaviour depending on an act no source describes.

    🚨 **The slot is the pool's, and this resource takes it only when it is
    free or already ours.** Cognito allows a pool exactly one
    `PreTokenGeneration` trigger, so an unconditional attach is last-writer-wins:
    it silently replaces a BYO customer's own claims-enrichment trigger, and it
    lets two platform stacks sharing a pool each read a store the other never
    writes — every role switch reporting success and doing nothing. So the
    describe this already performs is also read for *what is attached*, and a
    slot held by anything else fails the deploy naming it. See [classifySlot] and
    [docs/plans/active-role-store-scoped-to-the-pool.md].

    🚨 **`UpdateUserPool` resets by omission.** The API requires "a value for all
    parameters that you don't want set to a default value". An attach that sends
    only `LambdaConfig` silently returns every other setting on that pool to its
    default — on a pool the framework did not create and whose configuration it
    never described. So every call here describes first and sends the pool's own
    configuration back whole, with one field changed. See [mergedUpdateInput].

    Mirrors the dynImport + hand-rolled shape of
    [AppSync_SourceApiAssociation_Retrying.res]: Pulumi serialises a dynamic
    provider's whole captured closure into stack state, so the SDK is imported
    lazily and nothing here captures a Pulumi Output. */

let log = ReventlessCore.Logger.fromEnv()

// ── The merge ────────────────────────────────────────────────────────────────

/** Keys `DescribeUserPool` returns that `UpdateUserPool` does not accept.

    A **denylist**, deliberately, and the choice matters. An allowlist that
    missed a field would omit it from the update and silently reset it — exactly
    the failure this whole resource exists to prevent, and one that succeeds
    quietly. A denylist that misses a read-only field instead makes AWS reject
    the call, which is loud, immediate, and fixable. When the two error shapes
    are "a customer's pool quietly loses a setting" and "the deploy fails with a
    parameter error", the second is the one to design for.

    `Name` is absent from this list because it is not dropped but *renamed* —
    `DescribeUserPool` returns `Name`, `UpdateUserPool` takes `PoolName`. */
let readOnlyKeys = [
  "Id",
  "Name",
  "Arn",
  "Status",
  "CreationDate",
  "LastModifiedDate",
  "SchemaAttributes",
  "AliasAttributes",
  "UsernameAttributes",
  "UsernameConfiguration",
  "EstimatedNumberOfUsers",
  "Domain",
  "CustomDomain",
  "SmsConfigurationFailure",
  "EmailConfigurationFailure",
]

/** The version of the pre-token-generation contract this resource attaches at.

    [Auth_ActiveRoleTrigger_Ops] implements `V1_0` — it answers with
    `claimsOverrideDetails` — and does so deliberately, because `V2_0`/`V3_0` buy
    access-token customisation it does not need and are gated behind the
    Essentials and Plus feature plans.

    🚨 **A pool left at a version the handler does not implement does not fail —
    it silently does nothing.** Cognito sends a `V2_0` event, the handler answers
    in `V1_0` shape, and the service ignores the answer. Sign-in succeeds, tokens
    mint, and the role narrowing never happens. So the version is not the pool's
    to keep: the trigger and the contract it speaks are one unit, and attaching
    the trigger means attaching its version too. */
let triggerVersion = "V1_0"

/** The pool's own configuration, sent back whole with the pre-token-generation
    trigger set (or, when `preTokenGenerationArn` is `None`, removed).

    Pure and total so the property that matters — a pool carrying non-default
    settings still carries them afterwards — is checkable without a pool. */
let mergedUpdateInput = (
  ~described: dict<JSON.t>,
  ~userPoolId: string,
  ~preTokenGenerationArn: option<string>,
): dict<JSON.t> => {
  let out = Dict.make()
  described->Dict.forEachWithKey((value, key) =>
    if !(readOnlyKeys->Array.includes(key)) {
      out->Dict.set(key, value)
    }
  )
  described->Dict.get("Name")->Option.forEach(name => out->Dict.set("PoolName", name))
  out->Dict.set("UserPoolId", JSON.Encode.string(userPoolId))

  // The pool's other triggers are carried through untouched. Replacing the whole
  // `LambdaConfig` with a single-key object would silently detach every trigger
  // the customer already had — the reset-by-omission hazard one level down.
  let lambdaConfig =
    described
    ->Dict.get("LambdaConfig")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.mapOr(Dict.make(), existing => Dict.fromArray(existing->Dict.toArray))
  // 🚨 Cognito carries this one trigger in TWO fields: the legacy
  // `PreTokenGeneration` string and the `PreTokenGenerationConfig` object.
  // `UpdateUserPool` rejects the call outright when both are present naming
  // different functions, so both are written, together, naming the same one.
  //
  // Writing only one and letting the other ride through on the copy above cannot
  // work, and not merely because a customer might have set it: **AWS
  // materialises the field we did not write.** Attach via the legacy field alone
  // and the next `DescribeUserPool` reports a `PreTokenGenerationConfig` the
  // service populated, which the merge would then feed back on the following
  // deploy — so an attachment that succeeded once fails the next time with
  // nothing changed but AWS normalising its own record. Writing the pair in
  // agreement is the only form stable under repeated describe → merge → update.
  switch preTokenGenerationArn {
  | Some(arn) =>
    let config = Dict.make()
    config->Dict.set("LambdaArn", JSON.Encode.string(arn))
    config->Dict.set("LambdaVersion", JSON.Encode.string(triggerVersion))
    lambdaConfig->Dict.set("PreTokenGeneration", JSON.Encode.string(arn))
    lambdaConfig->Dict.set("PreTokenGenerationConfig", JSON.Encode.object(config))
  | None =>
    // Both, or the destroyed function stays attached through whichever field was
    // left behind — the "every sign-in fails on a pool nothing here would fix"
    // hazard [delete_] exists to prevent.
    lambdaConfig->Dict.delete("PreTokenGeneration")
    lambdaConfig->Dict.delete("PreTokenGenerationConfig")
  }
  out->Dict.set("LambdaConfig", lambdaConfig->JSON.Encode.object)
  out
}

/** Whatever function currently holds the pool's pre-token-generation slot,
    regardless of the contract version it is held at.

    Prefers `PreTokenGenerationConfig`, since that is the field AWS populates.

    Version-blind on purpose, and that is what separates it from
    [attachedTrigger]: this answers "is the slot occupied, and by whom" — the
    question the takeover check asks. A foreign trigger pinned at `V2_0` is very
    much attached, and a reader that reported it as absent would have this
    resource quietly replace exactly the trigger it is meant to refuse. */
let attachedTriggerArn = (~described: dict<JSON.t>): option<string> => {
  let lambdaConfig = described->Dict.get("LambdaConfig")->Option.flatMap(JSON.Decode.object)
  switch lambdaConfig
  ->Option.flatMap(c => c->Dict.get("PreTokenGenerationConfig"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(config => config->Dict.get("LambdaArn"))
  ->Option.flatMap(JSON.Decode.string) {
  | Some(_) as arn => arn
  | None =>
    lambdaConfig
    ->Option.flatMap(c => c->Dict.get("PreTokenGeneration"))
    ->Option.flatMap(JSON.Decode.string)
  }
}

/** The trigger currently attached to a described pool **at a version this
    handler implements**, if any.

    A pool whose `LambdaVersion` names a contract [triggerVersion] does not
    implement reports `None` — *not attached* — even when it points at our own
    function. That is what turns the silent-no-op case into ordinary drift:
    refresh records nothing attached, and the next `up` rewrites the pair at the
    right version. Reporting the ARN instead would leave a pool that mints
    un-narrowed tokens looking correct forever. */
let attachedTrigger = (~described: dict<JSON.t>): option<string> => {
  let lambdaConfig = described->Dict.get("LambdaConfig")->Option.flatMap(JSON.Decode.object)
  switch lambdaConfig
  ->Option.flatMap(c => c->Dict.get("PreTokenGenerationConfig"))
  ->Option.flatMap(JSON.Decode.object) {
  | Some(config) =>
    switch config->Dict.get("LambdaVersion")->Option.flatMap(JSON.Decode.string) {
    | Some(version) if version != triggerVersion => None
    | _ => config->Dict.get("LambdaArn")->Option.flatMap(JSON.Decode.string)
    }
  | None =>
    lambdaConfig
    ->Option.flatMap(c => c->Dict.get("PreTokenGeneration"))
    ->Option.flatMap(JSON.Decode.string)
  }
}

// ── Whose slot is it ─────────────────────────────────────────────────────────

/** What this deployment found in the pool's one pre-token-generation slot. */
type slot =
  /** Nothing attached. */
  | Vacant
  /** This deployment's own trigger. */
  | Ours
  /** Another deployment's active-role trigger, reading the **same** store.

    Not a conflict. Two platform stacks sharing a pool run the same code over the
    same rows, so whichever holds the slot serves both — which is the whole point
    of naming one store with `platform:activeRoleStore`. */
  | SharedWith(string)
  /** Another deployment's active-role trigger, reading a **different** store.

    The defect itself, caught at the only moment anything can see both halves:
    this stack's write door would write rows that trigger never reads. */
  | DifferentStore({arn: string, theirStore: string})
  /** Something that is not one of ours at all. */
  | Foreign(string)

/**
Which of the five a described pool presents.

Pure and total, like [mergedUpdateInput] and [probeVerdict], so every branch is
checkable without a pool. `attachedStore` is the `ACTIVE_ROLE_TABLE` the attached
function is configured with — `None` when it carries none, or when it could not
be read at all.

Reading the *store* rather than matching a function name is what makes this a
check on the invariant rather than on a convention: two triggers agree exactly
when the rows they read are the rows the other's resolver writes, and that is a
fact about their configuration, not about what they are called.
*/
let classifySlot = (
  ~attachedArn: option<string>,
  ~ourArn: string,
  ~ourStore: string,
  ~attachedStore: option<string>,
): slot =>
  switch attachedArn {
  | None | Some("") => Vacant
  | Some(arn) if arn == ourArn => Ours
  | Some(arn) =>
    switch attachedStore {
    | Some(store) if store == ourStore => SharedWith(arn)
    | Some(store) => DifferentStore({arn, theirStore: store})
    | None => Foreign(arn)
    }
  }

/**
The sentence to fail the deploy with, or `None` to proceed.

🚨 **The same trade [readOnlyKeys] makes.** Today this resource replaces whatever
it finds, so a BYO customer's own claims-enrichment trigger is silently detached
by a deploy — on a pool the framework went to considerable lengths not to
otherwise disturb. Given "a customer's pool quietly loses a trigger" and "the
deploy fails naming what is in the way", the second is the one to design for.

Both refusals name what is attached, because the operator cannot act on either
without knowing which function holds the slot.
*/
let refusalFor = (~slot: slot, ~userPoolId: string, ~ourStore: string): option<string> =>
  switch slot {
  | Vacant | Ours | SharedWith(_) => None
  | DifferentStore({arn, theirStore}) =>
    Some(
      `user pool ${userPoolId} already carries the active-role trigger ${arn}, which reads "${theirStore}" — but this deployment's Platform_SetActiveRole writes "${ourStore}". A pool holds one pre-token-generation trigger, so attaching would leave one of the two stacks writing rows nothing reads and every role switch silently doing nothing. Point both stacks at one store with platform:activeRoleStore, or give them separate user pools.`,
    )
  | Foreign(arn) =>
    Some(
      `user pool ${userPoolId} already carries the pre-token-generation trigger ${arn}, which is not an active-role trigger of this framework — attaching would silently replace it, and Cognito allows a pool only one. Detach it deliberately if it is obsolete, or give this deployment its own user pool. (If it *is* a Reventless trigger, this deployment could not read its configuration: the deploying principal needs lambda:GetFunctionConfiguration on it.)`,
    )
  }

// ── AWS SDK bindings (lazily imported — see AppSync_SourceApiAssociation_Retrying) ──

type cognitoClient

type describeInput = {@as("UserPoolId") userPoolId: string}
type describeResult = {@as("UserPool") userPool?: JSON.t}

type describeCmd
type updateCmd

type sdkModule = {
  @as("CognitoIdentityProviderClient") clientCtor: unit => cognitoClient,
  @as("DescribeUserPoolCommand") describeCtor: describeInput => describeCmd,
  @as("UpdateUserPoolCommand") updateCtor: dict<JSON.t> => updateCmd,
}

// Calls a constructor with `new` — the SDK exports plain classes.
//
// `%raw` here rather than a companion `.mjs` bound through `@module`, matching
// [AppSync_SourceApiAssociation_Retrying.res]: Pulumi serialises this provider's
// whole closure into stack state, and a helper reached through a module import
// is a dependency that serialisation cannot carry. Inline source can be.
let newOf1: ('ctor, 'arg) => 'r = %raw(`(C, x) => new C(x)`)
let newOf0: 'ctor => 'r = %raw(`(C) => new C()`)

@send external sendDescribe: (cognitoClient, describeCmd) => promise<describeResult> = "send"
@send external sendUpdate: (cognitoClient, updateCmd) => promise<unit> = "send"

// Emitted as a literal `import("...")` so the Pulumi serialiser does not
// statically capture the module in the provider closure.
@val external dynImport: string => promise<sdkModule> = "import"

let _sdk: ref<option<sdkModule>> = ref(None)
let _client: ref<option<cognitoClient>> = ref(None)

let getSdk = async (): sdkModule =>
  switch _sdk.contents {
  | Some(m) => m
  | None =>
    let m = await dynImport("@aws-sdk/client-cognito-identity-provider")
    _sdk.contents = Some(m)
    m
  }

let getClient = async (): cognitoClient =>
  switch _client.contents {
  | Some(c) => c
  | None =>
    let sdk = await getSdk()
    let c = newOf0(sdk.clientCtor)
    _client.contents = Some(c)
    c
  }

// ── Lambda bindings, for proving the trigger before attaching it ─────────────

type lambdaClient
type invokeCmd

type configCmd

type lambdaSdkModule = {
  @as("LambdaClient") clientCtor: unit => lambdaClient,
  @as("InvokeCommand") invokeCtor: dict<JSON.t> => invokeCmd,
  @as("GetFunctionConfigurationCommand") configCtor: dict<JSON.t> => configCmd,
}

type invokeResult = {
  @as("FunctionError") functionError?: string,
  @as("Payload") payload?: JSON.t,
}

type configResult = {@as("Environment") environment?: JSON.t}

@send external sendInvoke: (lambdaClient, invokeCmd) => promise<invokeResult> = "send"
@send external sendGetConfig: (lambdaClient, configCmd) => promise<configResult> = "send"
@val external dynImportLambda: string => promise<lambdaSdkModule> = "import"

let _lambdaSdk: ref<option<lambdaSdkModule>> = ref(None)
let _lambdaClient: ref<option<lambdaClient>> = ref(None)

let getLambdaSdk = async (): lambdaSdkModule =>
  switch _lambdaSdk.contents {
  | Some(m) => m
  | None =>
    let m = await dynImportLambda("@aws-sdk/client-lambda")
    _lambdaSdk.contents = Some(m)
    m
  }

let getLambdaClient = async (): lambdaClient =>
  switch _lambdaClient.contents {
  | Some(c) => c
  | None =>
    let sdk = await getLambdaSdk()
    let c = newOf0(sdk.clientCtor)
    _lambdaClient.contents = Some(c)
    c
  }

/** The store an already-attached function reads, from its own configuration.

    `None` covers three cases on purpose — no `Environment`, no
    `ACTIVE_ROLE_TABLE` in it, and the call failing outright (a deleted function,
    a cross-account ARN, a deploying principal without
    `lambda:GetFunctionConfiguration`). All three mean the same thing here: this
    deployment cannot establish that the attached trigger reads what its own
    resolver writes, and [refusalFor]'s `Foreign` sentence names every one of
    them. Failing closed is the point — the alternative is taking the slot on the
    strength of a lookup that did not happen. */
let activeRoleStoreOf = async (~functionArn: string): option<string> =>
  try {
    let sdk = await getLambdaSdk()
    let client = await getLambdaClient()
    let input = Dict.make()
    input->Dict.set("FunctionName", JSON.Encode.string(functionArn))
    let result = await client->sendGetConfig(newOf1(sdk.configCtor, input))
    result.environment
    ->Option.flatMap(JSON.Decode.object)
    ->Option.flatMap(env => env->Dict.get("Variables"))
    ->Option.flatMap(JSON.Decode.object)
    ->Option.flatMap(vars => vars->Dict.get("ACTIVE_ROLE_TABLE"))
    ->Option.flatMap(JSON.Decode.string)
  } catch {
  | _ => None
  }

/** Decodes the SDK's `Payload`, which arrives as a byte array rather than a
    string. */
let decodePayload: JSON.t => string = %raw(`(p) => {
  if (p == null) return "";
  if (typeof p === "string") return p;
  try { return new TextDecoder().decode(p); } catch { return String(p); }
}`)

@get @return(nullable) external exnName: JsExn.t => option<string> = "name"

let isPoolGoneError = (jsErr: JsExn.t): bool =>
  switch (jsErr->exnName, JsExn.message(jsErr)) {
  | (Some("ResourceNotFoundException"), _) => true
  | (_, Some(msg)) => msg->String.includes("ResourceNotFoundException")
  | _ => false
  }

// ── Prove the trigger before attaching it ────────────────────────────────────

/** The subject the probe presents. It is not a real user and must never match
    one: the handler looks the id up in the role table, and a probe that
    collided with a real row would exercise a different branch than the one it
    is here to check. */
let probeSubject = "reventless-attachment-probe"

/** The app client the probe presents, and like [probeSubject] it must match no
    real one — together they form the row key, and a collision would exercise a
    stored preference rather than the empty path this is checking. */
let probeClientId = "reventless-attachment-probe-client"

/** A minimal `V1_0` pre-token-generation event.

    Empty membership on purpose — with no groups and no stored role there is
    nothing to narrow, so a healthy handler returns the event unchanged. The
    probe is checking that the function *runs*, not what it decides; what it
    decides has unit tests, and they do not need a deployed pool. */
let probeEvent = (~userPoolId: string): JSON.t => {
  let groupConfiguration = Dict.make()
  groupConfiguration->Dict.set("groupsToOverride", JSON.Encode.array([]))
  groupConfiguration->Dict.set("iamRolesToOverride", JSON.Encode.array([]))

  let userAttributes = Dict.make()
  userAttributes->Dict.set("sub", JSON.Encode.string(probeSubject))

  let request = Dict.make()
  request->Dict.set("userAttributes", JSON.Encode.object(userAttributes))
  request->Dict.set("groupConfiguration", JSON.Encode.object(groupConfiguration))

  // Carried because Cognito carries it, and the handler keys its row on it. A
  // probe without one takes the "no client id, nothing to look up" branch and
  // would report a function healthy without ever reaching the store — proving
  // less than it appears to.
  let callerContext = Dict.make()
  callerContext->Dict.set("clientId", JSON.Encode.string(probeClientId))

  let event = Dict.make()
  event->Dict.set("version", JSON.Encode.string("1"))
  event->Dict.set("triggerSource", JSON.Encode.string("TokenGeneration_Authentication"))
  event->Dict.set("userPoolId", JSON.Encode.string(userPoolId))
  event->Dict.set("userName", JSON.Encode.string(probeSubject))
  event->Dict.set("callerContext", JSON.Encode.object(callerContext))
  event->Dict.set("request", JSON.Encode.object(request))
  event->Dict.set("response", JSON.Encode.object(Dict.make()))
  JSON.Encode.object(event)
}

/** What one probe invocation proved.

    A variant rather than a bool so the two failures stay distinguishable: they
    have different causes and want different sentences. */
type probeVerdict =
  | Healthy
  | Crashed(string)
  | NotAnEvent

/** The verdict for a given invoke result.

    Pure and total, so every branch is checkable without a deployed function —
    the same reason [mergedUpdateInput] is. A payload that is not JSON at all
    counts as not an event rather than throwing: the point here is to produce a
    verdict, and a parse error escaping would fail the deploy with a message
    about JSON instead of about the trigger. */
let probeVerdict = (~functionError: option<string>, ~payload: string): probeVerdict =>
  switch functionError {
  | Some(kind) => Crashed(kind)
  | None =>
    // A trigger must hand the event back for Cognito to mint anything from. A
    // function that returns 200 with something else shaped is as fatal as one
    // that throws, and rather harder to notice.
    let hasRequest = try {
      payload
      ->JSON.parseOrThrow
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("request"))
      ->Option.isSome
    } catch {
    | _ => false
    }
    hasRequest ? Healthy : NotAnEvent
  }

/**
 Invoke the trigger once and refuse to attach it if it cannot answer.

 🚨 **This is the check that keeps a broken trigger off a live pool.** Cognito
 runs this function on every token it mints, and a function that throws fails the
 sign-in — so a trigger that cannot start does not degrade the feature, it takes
 authentication away from every user of the pool. Nothing downstream notices: the
 deploy reports success, and the first report is a person unable to log in.

 A trigger cannot make itself fail open. It dies at module load, before any
 handler code runs, so no `try` inside the handler can catch it. The only place
 that can refuse a broken function is the thing about to point a pool at it, and
 that is here.

 So: broken function → this throws → the deploy fails with the function's own
 error → **the pool is never touched**. That is the same trade [readOnlyKeys]
 already makes deliberately, where a loud failure beats a quiet reset.

 Needs `lambda:InvokeFunction` on the deploying principal.
 */
let verifyTrigger = async (~userPoolId: string, ~preTokenGenerationArn: string): unit => {
  let sdk = await getLambdaSdk()
  let client = await getLambdaClient()

  let input = Dict.make()
  input->Dict.set("FunctionName", JSON.Encode.string(preTokenGenerationArn))
  input->Dict.set("InvocationType", JSON.Encode.string("RequestResponse"))
  input->Dict.set("Payload", JSON.Encode.string(probeEvent(~userPoolId)->JSON.stringify))

  let result = await client->sendInvoke(newOf1(sdk.invokeCtor, input))
  let payload = result.payload->Option.mapOr("", decodePayload)

  // The payload carries the runtime's own error — module-resolution failures, a
  // missing environment variable, an unhandled throw. Surfaced verbatim because
  // it is the most useful sentence anyone debugging this will read.
  switch probeVerdict(~functionError=result.functionError, ~payload) {
  | Crashed(kind) =>
    JsError.throwWithMessage(
      `active-role trigger ${preTokenGenerationArn} failed its pre-attach check (${kind}) and was NOT attached to user pool ${userPoolId}. Attaching it would have failed every sign-in on that pool. The function reported: ${payload}`,
    )
  | NotAnEvent =>
    JsError.throwWithMessage(
      `active-role trigger ${preTokenGenerationArn} answered its pre-attach check with something that is not a pre-token-generation event, so it was NOT attached to user pool ${userPoolId}. Cognito would have failed every sign-in. It returned: ${payload}`,
    )
  | Healthy =>
    log.info(
      ~comp="Auth_ActiveRolePoolAttachment",
      `trigger ${preTokenGenerationArn} answered the pre-attach check; attaching to ${userPoolId}`,
    )
  }
}

// ── Describe → merge → update ────────────────────────────────────────────────

let describePool = async (~userPoolId: string): option<dict<JSON.t>> => {
  let sdk = await getSdk()
  let client = await getClient()
  let result = await client->sendDescribe(newOf1(sdk.describeCtor, {userPoolId: userPoolId}))
  result.userPool->Option.flatMap(JSON.Decode.object)
}

/** Send the merge for an already-described pool. */
let sendMerged = async (
  ~described: dict<JSON.t>,
  ~userPoolId: string,
  ~preTokenGenerationArn: option<string>,
): unit => {
  let sdk = await getSdk()
  let client = await getClient()
  let input = mergedUpdateInput(~described, ~userPoolId, ~preTokenGenerationArn)
  await client->sendUpdate(newOf1(sdk.updateCtor, input))
}

/** Describe succeeded but returned no pool body. Sending an update built from
    nothing is precisely the reset this resource exists to avoid. */
let throwOnEmptyDescribe = (~userPoolId: string) =>
  JsError.throwWithMessage(
    `DescribeUserPool returned no pool for "${userPoolId}"; refusing to send an UpdateUserPool that would reset it`,
  )

/**
Attach this deployment's trigger — after establishing that the slot is this
deployment's to take.

The order is the whole design. Describe once, then in turn: refuse a slot held by
a trigger that is not ours or reads a different store; prove our own function can
run; only then write. Every refusal happens before any `UpdateUserPool`, so a
pool that fails this is left exactly as it was found.
*/
let attachTrigger = async (
  ~userPoolId: string,
  ~preTokenGenerationArn: string,
  ~activeRoleStore: string,
): unit =>
  switch await describePool(~userPoolId) {
  | None => throwOnEmptyDescribe(~userPoolId)
  | Some(described) =>
    let attachedArn = attachedTriggerArn(~described)
    // Only for a slot held by something other than us — our own function's store
    // is the one we were handed, so asking AWS about it would prove nothing and
    // cost a call on the common path.
    let attachedStore = switch attachedArn {
    | Some(arn) if arn != preTokenGenerationArn && arn != "" =>
      await activeRoleStoreOf(~functionArn=arn)
    | _ => None
    }
    let slot = classifySlot(
      ~attachedArn,
      ~ourArn=preTokenGenerationArn,
      ~ourStore=activeRoleStore,
      ~attachedStore,
    )
    switch refusalFor(~slot, ~userPoolId, ~ourStore=activeRoleStore) {
    | Some(message) => JsError.throwWithMessage(message)
    | None => ()
    }
    switch slot {
    | SharedWith(arn) =>
      log.info(
        ~comp="Auth_ActiveRolePoolAttachment",
        `user pool ${userPoolId} carries active-role trigger ${arn} from another deployment, reading the same store "${activeRoleStore}" — taking the slot serves both`,
      )
    | _ => ()
    }
    await verifyTrigger(~userPoolId, ~preTokenGenerationArn)
    await sendMerged(~described, ~userPoolId, ~preTokenGenerationArn=Some(preTokenGenerationArn))
  }

// ── Dynamic provider ─────────────────────────────────────────────────────────

type providerInputs = {
  userPoolId: string,
  preTokenGenerationArn: string,
  /** The deployed function's code hash.

      Carried purely so a code change reaches this resource. The function ARN is
      stable across deploys, so without this the attachment sees identical inputs
      every time and never runs again — meaning [verifyTrigger] would prove the
      function once, on the deploy that created it, and never for any version
      shipped afterwards. A check that only ever runs once is not a check. */
  codeHash: string,
  /** The store this deployment's trigger reads and its write door writes.

      Carried so the takeover check can compare it against the store of whatever
      already holds the pool's slot — the comparison that decides whether two
      deployments sharing this pool agree or silently disagree. */
  activeRoleStore: string,
}

type createOuts = {
  userPoolId: string,
  preTokenGenerationArn: string,
  codeHash: string,
  activeRoleStore: string,
}

type createResult = {id: string, outs: createOuts}
type updateResult = {outs: createOuts}
type diffResult = {changes: bool, replaces: array<string>, deleteBeforeReplace: bool}
type readResult = {id?: string, props?: createOuts}

let create = async (inputs: providerInputs): createResult => {
  await attachTrigger(
    ~userPoolId=inputs.userPoolId,
    ~preTokenGenerationArn=inputs.preTokenGenerationArn,
    ~activeRoleStore=inputs.activeRoleStore,
  )
  {
    id: inputs.userPoolId,
    outs: {
      userPoolId: inputs.userPoolId,
      preTokenGenerationArn: inputs.preTokenGenerationArn,
      codeHash: inputs.codeHash,
      activeRoleStore: inputs.activeRoleStore,
    },
  }
}

let update = async (_id: string, _olds: createOuts, news: providerInputs): updateResult => {
  // Re-checked and re-proved on every update, not only on create: the usual
  // reason this runs is that the function's code changed, which is exactly when
  // it might have stopped working — and a slot this deployment held once can
  // have been taken since. The pool keeps the trigger it already has until this
  // succeeds.
  await attachTrigger(
    ~userPoolId=news.userPoolId,
    ~preTokenGenerationArn=news.preTokenGenerationArn,
    ~activeRoleStore=news.activeRoleStore,
  )
  {
    outs: {
      userPoolId: news.userPoolId,
      preTokenGenerationArn: news.preTokenGenerationArn,
      codeHash: news.codeHash,
      activeRoleStore: news.activeRoleStore,
    },
  }
}

/** Detaching on destroy is not optional. The Lambda is torn down with the rest
    of the stack; a pool left pointing at a deleted function fails **every**
    sign-in, and it is a pool the framework does not own — so nothing else in
    this deployment would ever put it right. A pool that has already gone is
    nothing to detach from.

    🚨 **Only when the slot still holds *our* function.** Where two stacks share
    a pool the later one takes the slot, and a blind detach here would then tear
    out a trigger this deployment does not own while destroying — reintroducing
    the outage this exists to prevent, from the opposite direction. What is left
    behind in that case is a healthy trigger reading the store both stacks share. */
let delete_ = async (_id: string, props: createOuts): unit =>
  try {
    switch await describePool(~userPoolId=props.userPoolId) {
    | None => throwOnEmptyDescribe(~userPoolId=props.userPoolId)
    | Some(described) =>
      switch attachedTriggerArn(~described) {
      | Some(arn) if arn == props.preTokenGenerationArn =>
        await sendMerged(~described, ~userPoolId=props.userPoolId, ~preTokenGenerationArn=None)
      | Some(arn) =>
        log.info(
          ~comp="Auth_ActiveRolePoolAttachment",
          `user pool ${props.userPoolId} carries ${arn}, not this deployment's trigger; leaving it attached`,
        )
      | None => ()
      }
    }
  } catch {
  | exn if exn->JsExn.fromException->Option.mapOr(false, isPoolGoneError) =>
    log.info(
      ~comp="Auth_ActiveRolePoolAttachment",
      `user pool ${props.userPoolId} is gone; nothing to detach`,
    )
  }

/** A different pool is a different attachment: the old pool must be detached
    before the new one is attached, so this replaces rather than updates in
    place. Changing only the function ARN, its code, or the store it reads is an
    ordinary update — each is a reason to run the takeover check again. */
let diff_ = (_id: string, olds: createOuts, news: providerInputs): diffResult => {
  let poolChanged = olds.userPoolId != news.userPoolId
  {
    changes: poolChanged ||
    olds.preTokenGenerationArn != news.preTokenGenerationArn ||
    olds.codeHash != news.codeHash ||
    olds.activeRoleStore != news.activeRoleStore,
    replaces: poolChanged ? ["userPoolId"] : [],
    deleteBeforeReplace: true,
  }
}

/** Live state for `pulumi refresh`: report what the pool actually carries, so a
    trigger detached out of band shows as drift and the next `up` re-attaches
    it. A missing pool drops the resource from state. */
let read_ = async (id: string, props: createOuts): readResult =>
  try {
    switch await describePool(~userPoolId=props.userPoolId) {
    | None => ({}: readResult)
    | Some(described) => {
        id,
        props: {
          userPoolId: props.userPoolId,
          preTokenGenerationArn: attachedTrigger(~described)->Option.getOr(""),
          // The pool cannot report what code the function is running, so the
          // recorded hash is carried through unchanged. Refresh answers "is the
          // right function attached", which is what the pool actually knows.
          codeHash: props.codeHash,
          // Likewise not the pool's to report — it is a property of whatever
          // function holds the slot, and refresh is about the pool.
          activeRoleStore: props.activeRoleStore,
        },
      }
    }
  } catch {
  | exn if exn->JsExn.fromException->Option.mapOr(false, isPoolGoneError) => ({}: readResult)
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

type t = {id: Pulumi.Output.t<string>}

type constructorProps = {
  userPoolId: Pulumi.Input.t<string>,
  preTokenGenerationArn: Pulumi.Input.t<string>,
  codeHash: Pulumi.Input.t<string>,
  activeRoleStore: Pulumi.Input.t<string>,
}

// Explicit /index.js path because @pulumi/pulumi/dynamic is a directory import
// not resolvable in ESM mode.
@module("@pulumi/pulumi/dynamic/index.js") @new
external _newResource: ('provider, string, 'props, Pulumi.CustomResourceOptions.t) => t = "Resource"

let make = (
  ~name: string="ActiveRolePoolAttachment",
  ~props: constructorProps,
  ~opts: Pulumi.CustomResourceOptions.t,
): t => _newResource(provider, name, props, opts)
