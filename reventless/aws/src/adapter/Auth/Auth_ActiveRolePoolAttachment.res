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

/** The pool's own configuration, sent back whole with `PreTokenGeneration` set
    (or, when `preTokenGenerationArn` is `None`, removed).

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
  switch preTokenGenerationArn {
  | Some(arn) => lambdaConfig->Dict.set("PreTokenGeneration", JSON.Encode.string(arn))
  | None => lambdaConfig->Dict.delete("PreTokenGeneration")
  }
  out->Dict.set("LambdaConfig", lambdaConfig->JSON.Encode.object)
  out
}

/** The trigger currently attached to a described pool, if any. */
let attachedTrigger = (~described: dict<JSON.t>): option<string> =>
  described
  ->Dict.get("LambdaConfig")
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(c => c->Dict.get("PreTokenGeneration"))
  ->Option.flatMap(JSON.Decode.string)

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

@get @return(nullable) external exnName: JsExn.t => option<string> = "name"

let isPoolGoneError = (jsErr: JsExn.t): bool =>
  switch (jsErr->exnName, JsExn.message(jsErr)) {
  | (Some("ResourceNotFoundException"), _) => true
  | (_, Some(msg)) => msg->String.includes("ResourceNotFoundException")
  | _ => false
  }

// ── Describe → merge → update ────────────────────────────────────────────────

let describePool = async (~userPoolId: string): option<dict<JSON.t>> => {
  let sdk = await getSdk()
  let client = await getClient()
  let result = await client->sendDescribe(newOf1(sdk.describeCtor, {userPoolId: userPoolId}))
  result.userPool->Option.flatMap(JSON.Decode.object)
}

/** Set (or clear) the pool's pre-token-generation trigger, preserving every
    other setting the pool carries. */
let applyTrigger = async (~userPoolId: string, ~preTokenGenerationArn: option<string>): unit => {
  let sdk = await getSdk()
  let client = await getClient()
  switch await describePool(~userPoolId) {
  | None =>
    // Describe succeeded but returned no pool body. Sending an update built from
    // nothing is precisely the reset this resource exists to avoid.
    JsError.throwWithMessage(
      `DescribeUserPool returned no pool for "${userPoolId}"; refusing to send an UpdateUserPool that would reset it`,
    )
  | Some(described) =>
    let input = mergedUpdateInput(~described, ~userPoolId, ~preTokenGenerationArn)
    await client->sendUpdate(newOf1(sdk.updateCtor, input))
  }
}

// ── Dynamic provider ─────────────────────────────────────────────────────────

type providerInputs = {
  userPoolId: string,
  preTokenGenerationArn: string,
}

type createOuts = {
  userPoolId: string,
  preTokenGenerationArn: string,
}

type createResult = {id: string, outs: createOuts}
type updateResult = {outs: createOuts}
type diffResult = {changes: bool, replaces: array<string>, deleteBeforeReplace: bool}
type readResult = {id?: string, props?: createOuts}

let create = async (inputs: providerInputs): createResult => {
  await applyTrigger(
    ~userPoolId=inputs.userPoolId,
    ~preTokenGenerationArn=Some(inputs.preTokenGenerationArn),
  )
  {
    id: inputs.userPoolId,
    outs: {userPoolId: inputs.userPoolId, preTokenGenerationArn: inputs.preTokenGenerationArn},
  }
}

let update = async (_id: string, _olds: createOuts, news: providerInputs): updateResult => {
  await applyTrigger(
    ~userPoolId=news.userPoolId,
    ~preTokenGenerationArn=Some(news.preTokenGenerationArn),
  )
  {outs: {userPoolId: news.userPoolId, preTokenGenerationArn: news.preTokenGenerationArn}}
}

/** Detaching on destroy is not optional. The Lambda is torn down with the rest
    of the stack; a pool left pointing at a deleted function fails **every**
    sign-in, and it is a pool the framework does not own — so nothing else in
    this deployment would ever put it right. A pool that has already gone is
    nothing to detach from. */
let delete_ = async (_id: string, props: createOuts): unit =>
  try {
    await applyTrigger(~userPoolId=props.userPoolId, ~preTokenGenerationArn=None)
  } catch {
  | exn if exn->JsExn.fromException->Option.mapOr(false, isPoolGoneError) =>
    log.info(
      ~comp="Auth_ActiveRolePoolAttachment",
      `user pool ${props.userPoolId} is gone; nothing to detach`,
    )
  }

/** A different pool is a different attachment: the old pool must be detached
    before the new one is attached, so this replaces rather than updates in
    place. Changing only the function ARN is an ordinary update. */
let diff_ = (_id: string, olds: createOuts, news: providerInputs): diffResult => {
  let poolChanged = olds.userPoolId != news.userPoolId
  {
    changes: poolChanged || olds.preTokenGenerationArn != news.preTokenGenerationArn,
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
