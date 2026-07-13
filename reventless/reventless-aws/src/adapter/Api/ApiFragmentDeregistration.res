/** Pulumi dynamic resource whose sole purpose is to deregister a plugin's
    API-schema fragment on `pulumi destroy` (final retirement of the plugin
    stack). `create` / `update` are no-ops — registration is done by
    `Platform.registerFragmentViaApi` at deploy time; only `delete` matters,
    and it calls `Platform_DeregisterApiFragment` on the platform's Platform API
    (SigV4), whose event triggers the platform-side reactive single writer (2e)
    to re-stitch the schema WITHOUT this plugin's fields.

    Serialization: Pulumi serialises the provider object (and its captured import
    closure) into stack state, so it must NOT statically capture the AWS SDK —
    that breaks Pulumi's closure serialiser (the CJS/ESM dual-export confusion
    documented in AppSync_Resolver_Retrying). The delete handler therefore
    DYNAMICALLY imports the signed caller at invocation time; only the string
    specifier lands in state.

    Version supersession must NOT deregister: `diff` never reports changes/replaces
    (pluginId, endpoint, and region are all version-stable), so a version bump is
    an in-place no-op and the `delete` handler fires only on a genuine stack
    destroy — the "final retirement, resolvers gone" trigger. */

let log = ReventlessCore.Logger.fromEnv()

type providerInputs = {
  pluginId: string,
  endpoint: string,
  region: string,
}

// Pulumi passes OUTPUTS (possibly undefined) to delete/read handlers, so encode
// the carrier fields into the resource id — always available. "|" cannot appear
// in a plugin name, an AWS region, or an AppSync GraphQL endpoint URL.
let encodeId = (i: providerInputs): string => `${i.pluginId}|${i.region}|${i.endpoint}`
let decodeId = (id: string): option<providerInputs> =>
  switch id->String.split("|") {
  | [pluginId, region, endpoint] => Some({pluginId, region, endpoint})
  | _ => None
  }

// Dynamically import the signed caller and send Platform_DeregisterApiFragment.
// The `import(...)` keeps Util_AppSync_Caller (and its transitive @aws-sdk/@smithy
// deps) OUT of the serialised provider closure — only this string is captured.
// Positional call matches the compiled signature
// `sendMutation(endpoint, region, mutation, selection, variables)`.
let sendDeregister: (JSON.t, string, string) => promise<unit> = %raw(`
  async function (variables, endpoint, region) {
    const mod = await import("@reventlessdev/reventless-aws/src/util/Util_AppSync_Caller.res.mjs");
    await mod.sendMutation(endpoint, region, "Platform_ApiFragmentRegistry_DeregisterApiFragment", "{ __typename }", variables);
  }
`)

let errMessage: 'a => string = %raw(`(e) => (e && e.message) ? String(e.message) : String(e)`)

type createResult = {id: string, outs: providerInputs}
type updateResult = {outs: providerInputs}
type diffResult = {changes: bool, replaces: array<string>, deleteBeforeReplace: bool}

let create = async (inputs: providerInputs): createResult => {id: encodeId(inputs), outs: inputs}

let update = async (_id: string, _olds: providerInputs, news: providerInputs): updateResult => {
  outs: news,
}

// Never change/replace — see the module note: keeps version bumps from deleting
// (and therefore deregistering) the fragment.
let diff = (_id: string, _olds: providerInputs, _news: providerInputs): diffResult => {
  changes: false,
  replaces: [],
  deleteBeforeReplace: false,
}

let delete_ = async (id: string, props: providerInputs): unit => {
  let carrier = switch decodeId(id) {
  | Some(c) => c
  | None => props
  }
  let variables =
    Dict.fromArray([
      // Platform_ApiFragmentRegistry_DeregisterApiFragment(id: ID!, pluginId: ID!) — the
      // registry is a SINGLETON aggregate, so `id` is the fixed constant; `pluginId`
      // (payload) names the plugin whose fragment is removed.
      ("id", JSON.Encode.string("registry")),
      ("pluginId", JSON.Encode.string(carrier.pluginId)),
    ])->JSON.Encode.object
  // Best-effort: on a full teardown the platform API may already be gone, and a
  // destroy must not fail because deregistration could not reach it.
  try {
    await sendDeregister(variables, carrier.endpoint, carrier.region)
    log.info(~comp="ApiFragmentDeregistration", `Deregistered API fragment for ${carrier.pluginId}`)
  } catch {
  | exn =>
    log.warn(
      ~comp="ApiFragmentDeregistration",
      `deregister for ${carrier.pluginId} failed (best-effort; platform may be gone): ${errMessage(
          exn,
        )}`,
    )
  }
}

// Provider as a plain JS object — no Pulumi Output captures; all state flows
// through inputs / id.
let provider = {
  "create": create,
  "update": update,
  "delete": delete_,
  "diff": diff,
}

// ── Pulumi dynamic resource binding ──────────────────────────────────────────

type t

type constructorProps = {
  pluginId: Pulumi.Input.t<string>,
  endpoint: Pulumi.Input.t<string>,
  region: Pulumi.Input.t<string>,
}

// pulumi.dynamic.Resource constructor: (provider, name, props, opts). Explicit
// /index.js path because @pulumi/pulumi/dynamic is a directory import not
// resolvable in ESM mode.
@module("@pulumi/pulumi/dynamic/index.js") @new
external _newResource: ('provider, string, 'props, Pulumi.CustomResourceOptions.t) => t = "Resource"

let make = (
  ~name: string,
  ~pluginId: string,
  ~endpoint: Pulumi.Input.t<string>,
  ~region: string,
  ~opts: Pulumi.CustomResourceOptions.t={},
): t => {
  let props: constructorProps = {
    pluginId: pluginId->Pulumi.Input.make,
    endpoint,
    region: region->Pulumi.Input.make,
  }
  _newResource(provider, name, props, opts)
}
