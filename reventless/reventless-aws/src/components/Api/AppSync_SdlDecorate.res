// AppSync_SdlDecorate.res
// Pure SDL decoration for the AppSync dialect — no AWS SDK, no Pulumi.
//
// Core emits provider-neutral SDL plus structured `subscriptionSource`
// metadata (which mutation(s) feed each subscription field). This module adds
// the AppSync-specific `@aws_subscribe(mutations: [...])` directive onto the
// STITCHED schema at push time — the additive counterpart of the neutral
// emission, mirroring how `injectAwsAuthAll`/`stampSharedIamTypes` decorate
// auth. Runtime-pure so the bundled Lambda entry points
// (AdminEventCollectorEntryPoint.mjs) can import it without dragging
// deploy-time dependencies into the runtime module graph.

/**
Append `@aws_subscribe(mutations: [...])` to every field of the SDL's
`type Subscription { … }` block that has a source mapping. Fields without a
mapping (e.g. Source A event-stream fields, pushed via the Events API) are
left untouched. No-op when the SDL has no Subscription block or `sources` is
empty.
*/
let injectAwsSubscribe = (
  sdl: string,
  ~sources: array<ReventlessCore.GraphQL_Stitcher.subscriptionSource>,
): string => {
  if sources->Array.length == 0 {
    sdl
  } else {
    let sourceByField: Dict.t<array<string>> = Dict.make()
    sources->Array.forEach(source => sourceByField->Dict.set(source.field, source.mutations))
    switch sdl->String.indexOfOpt("type Subscription") {
    | None => sdl
    | Some(blockStart) =>
      let before = sdl->String.slice(~start=0, ~end=blockStart)
      let rest = sdl->String.slice(~start=blockStart)
      switch rest->String.indexOfOpt("}") {
      | None => sdl
      | Some(closeIdx) =>
        let block = rest->String.slice(~start=0, ~end=closeIdx)
        let after = rest->String.slice(~start=closeIdx)
        let decorated =
          block
          ->String.split("\n")
          ->Array.map(line => {
            // `name(args): T` → the arg list is stripped; `name: T` (no args)
            // leaves a trailing colon on the token — drop it (same rule as
            // GraphQL_Stitcher.rootTypeFieldNames).
            let name = ReventlessCore.GraphQL_Stitcher.extractLeadingName(line)
            let name = name->String.endsWith(":")
              ? name->String.slice(~start=0, ~end=name->String.length - 1)
              : name
            switch sourceByField->Dict.get(name) {
            | Some(mutations) =>
              let list = mutations->Array.map(m => `"${m}"`)->Array.join(", ")
              `${line}\n    @aws_subscribe(mutations: [${list}])`
            | None => line
            }
          })
          ->Array.join("\n")
        before ++ decorated ++ after
      }
    }
  }
}

// ── Auth decoration (runtime-pure) ───────────────────────────────────────────
// Moved here from AppSync_Adapter so the reactive single-writer push (the
// bundled AdminEventCollector Lambda) can decorate the admin base identically to
// the deploy path without dragging Pulumi into the runtime graph. AppSync_Adapter
// delegates its `injectAwsAuthAll` / `stampSharedIamTypes` to these definitions.

// Multi-auth directive for a field/type that must accept BOTH Cognito and IAM.
// `groups=Some([...])` preserves Cognito group gating; `groups=None` keeps it
// open to any authenticated Cognito user. `@aws_iam` admits the deploy-time
// SigV4 system caller.
let formatDualAuthDirective = (groups: option<array<string>>): string => {
  let cognito = switch groups {
  | Some(g) =>
    let quoted = g->Array.map(x => `"${x}"`)->Array.join(", ")
    `@aws_cognito_user_pools(cognito_groups: [${quoted}])`
  | None => `@aws_cognito_user_pools`
  }
  `${cognito} @aws_iam`
}

// Injects @aws_auth with the given group on ALL mutation, query, and subscription
// fields in a fragment. `~iamFieldNames` opts the named mutation/query fields into
// deploy-time IAM (dual-auth): those fields emit
// `@aws_cognito_user_pools(cognito_groups: ["<group>"]) @aws_iam` instead of the
// single-mode `@aws_auth(...)`, keeping the same Cognito gating while also admitting
// the SigV4 system caller. Subscriptions are never IAM-marked.
let injectAwsAuthAll = (
  fragment: Reventless.Plugin.apiSchemaFragment,
  ~group: string,
  ~iamFieldNames: array<string>=[],
): Reventless.Plugin.apiSchemaFragment => {
  let parts = ReventlessCore.GraphQL_Stitcher.decode(fragment)
  let isIam = (field: string): bool =>
    iamFieldNames->Array.includes(ReventlessCore.GraphQL_Stitcher.extractLeadingName(field))

  let augmentedMutations = parts.mutations->Array.map(field =>
    isIam(field)
      ? `${field}\n    ${formatDualAuthDirective(Some([group]))}`
      : `${field}\n    @aws_auth(cognito_groups: ["${group}"])`
  )
  let augmentedQueries = parts.queries->Array.map(field =>
    isIam(field)
      ? `${field} ${formatDualAuthDirective(Some([group]))}`
      : `${field} @aws_auth(cognito_groups: ["${group}"])`
  )
  let augmentedSubscriptions = parts.subscriptions->Array.map(field =>
    `${field}\n    @aws_auth(cognito_groups: ["${group}"])`
  )

  ReventlessCore.GraphQL_Stitcher.encode({
    ...parts,
    mutations: augmentedMutations,
    queries: augmentedQueries,
    subscriptions: augmentedSubscriptions,
  })
}

// Shared traversal types every callable surface reaches — `PageInfo` (relay
// connections, injected by the stitcher), the `CommandResult` members (mutation
// returns, deduped across fragments by the stitcher), and `Platform_ApiFragmentEntry`
// (the return type of the IAM-callable `Platform_ApiFragments` status query the deploy
// waiter polls via SigV4 — without the type-level `@aws_iam` the SigV4 caller reaches the
// query field but is "Not Authorized to access <field> on type Platform_ApiFragmentEntry").
// Stamped once on the ASSEMBLED SDL: per-fragment stamping would race the stitcher's
// first-wins dedupe against unstamped sibling copies.
let sharedIamTypeNames = [
  "PageInfo",
  "CommandAccepted",
  "CommandRejected",
  "CommandPending",
  "Platform_ApiFragmentEntry",
]

let stampSharedIamTypes = (sdl: string): string =>
  sharedIamTypeNames->Array.reduce(sdl, (acc, name) =>
    acc->String.replace(`type ${name} {`, `type ${name} @aws_cognito_user_pools @aws_iam {`)
  )

// ── Reactive push planner (runtime-pure) ─────────────────────────────────────
// The AWS-decorated counterpart of core `GraphQL_PushPlanner.planPushes`: given
// the fragments currently in the ApiFragmentRegistry (each tagged with its target
// API, as the bare string "Domain" / "Platform"), it produces one fully
// AppSync-decorated SDL push plan per API. It reuses the core planner for the
// neutral base-selection + stitch, then applies the AppSync dialect exactly as the
// deploy path's `stitchWithAwsDirectives`:
//   - the admin base is auth-decorated (group "Admin" + dual-auth on the system-
//     caller field names) BEFORE stitching, so the Platform/unified base carries
//     @aws_auth/@aws_iam (the empty Domain-split base needs none);
//   - @aws_subscribe is injected from the neutral subscriptionSources metadata;
//   - the shared traversal types are stamped once on the assembled SDL.
// Plugin fragments already carry their own per-field @aws_auth (baked at
// generateFragment time), so they stitch in as-is. `api` comes back as the bare
// string "PlatformApi" / "DomainApi" for the mjs to map onto the AppSync ids.
type targetedFragmentInput = {
  encoded: string,
  protocol: string,
  // "Domain" | "Platform" — the bare-string runtime form of Reventless.Plugin.apiTarget.
  target: string,
}

type awsPushPlan = {
  // "PlatformApi" | "DomainApi" — the bare-string runtime form of GraphQL_PushPlanner.planTarget.
  api: string,
  sdl: string,
}

let planAwsPushes = (
  ~rawAdminBase: Reventless.Plugin.apiSchemaFragment,
  ~iamFieldNames: array<string>,
  ~fragments: array<targetedFragmentInput>,
  ~splitApi: bool,
): array<awsPushPlan> => {
  let authBase = injectAwsAuthAll(rawAdminBase, ~group="Admin", ~iamFieldNames)
  let targeted = fragments->Array.map((f): ReventlessCore.GraphQL_PushPlanner.targetedFragment => {
    fragment: {encoded: f.encoded, protocol: f.protocol},
    target: switch f.target {
    | "Platform" => Platform
    | _ => Domain
    },
  })
  let allFrags = targeted->Array.map(t => t.fragment)
  let sources = ReventlessCore.GraphQL_Stitcher.collectSubscriptionSources(
    ~baseFragment=rawAdminBase,
    ~pluginFragments=allFrags,
  )
  ReventlessCore.GraphQL_PushPlanner.planPushes(~adminBase=authBase, ~fragments=targeted, ~splitApi)
  ->Array.map(plan => {
    let sdl = plan.sdl->injectAwsSubscribe(~sources)->stampSharedIamTypes
    let api = switch plan.api {
    | PlatformApi => "PlatformApi"
    | DomainApi => "DomainApi"
    }
    {api, sdl}
  })
}
