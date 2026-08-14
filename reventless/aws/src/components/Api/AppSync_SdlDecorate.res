// AppSync_SdlDecorate.res
// Pure SDL decoration for the AppSync dialect — no AWS SDK, no Pulumi.
//
// Core emits provider-neutral SDL plus structured `subscriptionSource`
// metadata (which mutation(s) feed each subscription field). This module adds
// the AppSync-specific `@aws_subscribe(mutations: [...])` directive onto the
// STITCHED schema at push time — the additive counterpart of the neutral
// emission, mirroring how `injectAwsAuthAll`/`stampSharedIamTypes` decorate
// auth. Runtime-pure so the bundled Lambda entry points
// (EventCollectorEntryPoint.mjs) can import it without dragging
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

// Cognito group gate. `@aws_cognito_user_pools(cognito_groups: [...])` — NOT the
// single-mode `@aws_auth(cognito_groups: [...])`.
//
// `@aws_auth` is honoured only on an API whose sole authorization mode is
// AMAZON_COGNITO_USER_POOLS. This adapter always configures AWS_IAM as an
// additional provider (see AppSync_Adapter's api args — the server-to-server
// lambdas need it), so every API we provision is multi-auth and the service
// **silently ignores** `@aws_auth`: the schema deploys, the directive shows up
// in the deployed SDL, and it gates nothing. What is left is
// `userPoolConfig.defaultAction: ALLOW`, which admits every authenticated
// Cognito user — a group gate that fails open.
//
// Confirmed by observation against a deployed API: a user in no groups read
// every `@aws_auth`-gated field and reached a gated mutation's handler. See
// docs/plans/appsync-group-authorization-unenforced.md.
let formatCognitoGroupsDirective = (groups: array<string>): string => {
  let quoted = groups->Array.map(g => `"${g}"`)->Array.join(", ")
  `@aws_cognito_user_pools(cognito_groups: [${quoted}])`
}

// The group-less Cognito directive: reachable by any authenticated Cognito
// caller. Emitted where a field or type is deliberately open — `AllowAuthenticated`,
// `AllowAnonymous`, a field carrying no permission at all, and every object type.
//
// Under `userPoolConfig.defaultAction: ALLOW` this is a no-op: an undirectived
// field is already reachable by any authenticated caller, so stamping it changes
// nothing. It exists so the default can be flipped to DENY, where "no directive"
// stops meaning "open" and starts meaning "refused" — at which point anything
// left unstamped breaks. Stamping first and flipping second is what keeps that
// flip from being a guess.
let cognitoOpenDirective = "@aws_cognito_user_pools"

// Multi-auth directive for a field/type that must accept BOTH Cognito and IAM.
// `groups=Some([...])` preserves Cognito group gating; `groups=None` keeps it
// open to any authenticated Cognito user. `@aws_iam` admits the deploy-time
// SigV4 system caller.
let formatDualAuthDirective = (groups: option<array<string>>): string => {
  let cognito = switch groups {
  | Some(g) => formatCognitoGroupsDirective(g)
  | None => cognitoOpenDirective
  }
  `${cognito} @aws_iam`
}

// Injects the Cognito group gate on ALL mutation, query, and subscription fields
// in a fragment. `~iamFieldNames` opts the named mutation/query fields into
// deploy-time IAM as well, appending the `@aws_iam` arm. Subscriptions are never
// IAM-marked (the deploy caller does not subscribe) but still carry the Cognito
// gate — a subscription is a read.
let injectAwsAuthAll = (
  fragment: Reventless.Plugin.apiSchemaFragment,
  ~group: string,
  ~iamFieldNames: array<string>=[],
): Reventless.Plugin.apiSchemaFragment => {
  let parts = ReventlessCore.GraphQL_Stitcher.decode(fragment)
  let isIam = (field: string): bool =>
    iamFieldNames->Array.includes(ReventlessCore.GraphQL_Stitcher.extractLeadingName(field))
  let cognitoOnly = formatCognitoGroupsDirective([group])

  let augmentedMutations = parts.mutations->Array.map(field =>
    isIam(field)
      ? `${field}\n    ${formatDualAuthDirective(Some([group]))}`
      : `${field}\n    ${cognitoOnly}`
  )
  let augmentedQueries = parts.queries->Array.map(field =>
    isIam(field) ? `${field} ${formatDualAuthDirective(Some([group]))}` : `${field} ${cognitoOnly}`
  )
  let augmentedSubscriptions = parts.subscriptions->Array.map(field =>
    `${field}\n    ${cognitoOnly}`
  )

  ReventlessCore.GraphQL_Stitcher.encode({
    ...parts,
    mutations: augmentedMutations,
    queries: augmentedQueries,
    subscriptions: augmentedSubscriptions,
  })
}

// Shared traversal types every callable surface reaches — `PageInfo` (relay
// connections, injected by the stitcher) and the `CommandResult` members
// (mutation returns). Stamped once on the ASSEMBLED SDL so an IAM system
// caller (`@@reventless.systemCallable` fields) can traverse them.
let sharedIamTypeNames = [
  "PageInfo",
  "CommandAccepted",
  "CommandRejected",
  "CommandPending",
]

let stampSharedIamTypes = (sdl: string): string =>
  sharedIamTypeNames->Array.reduce(sdl, (acc, name) =>
    acc->String.replace(`type ${name} {`, `type ${name} @aws_cognito_user_pools @aws_iam {`)
  )

// Stamp every object `type` declaration that does not already carry an auth
// directive with the group-less Cognito arm. Run on the ASSEMBLED SDL, AFTER
// stampSharedIamTypes so the shared traversal types keep their `@aws_iam` arm
// (this pass skips anything already carrying an `@aws_` directive).
//
// Types, not just fields: on a multi-auth API with `defaultAction: DENY`,
// AppSync refuses an undirectived TYPE even when the caller passed the field's
// own gate — response shaping walks `…Connection` → `…Edge` → node → nested
// state types and dies one level in. Entry gating stays on the fields; a type
// stamp only restores the accessibility an undirectived type has today.
//
// Only `type` declarations take auth directives — `input`, `enum`, `union` and
// `interface` do not, and stamping them is a schema error.
let stampAllTypesCognito = (sdl: string): string =>
  sdl
  ->String.split("\n")
  ->Array.map(line =>
    if line->String.startsWith("type ") && !(line->String.includes("@aws_")) {
      switch line->String.indexOfOpt("{") {
      | Some(i) =>
        line->String.slice(~start=0, ~end=i) ++
        cognitoOpenDirective ++
        " " ++
        line->String.slice(~start=i, ~end=line->String.length)
      | None => line
      }
    } else {
      line
    }
  )
  ->Array.join("\n")

// ── Merged-API canonical stamping ─────────────────────────────────────────────
// Under AppSync Merged APIs the admin source API owns the shared traversal
// types; `@canonical` makes its definition win over every plugin source's copy
// (plugin copies must still exist — a source schema has to be valid standalone).
// Spike-validated (plan Phase 0): a divergent non-canonical copy is SHADOWED by
// the canonical definition, not a MERGE_FAILED — so this stamp is what keeps
// shared-type evolution single-owner. Applied only to the ADMIN source SDL on
// the merge path; plugin subgraph documents stay unstamped.

// Object types the admin source owns canonically. `interface Node` and
// `union CommandResult` are handled structurally below (their def lines don't
// start with `type `).
let canonicalTypeNames = ["PageInfo", "CommandAccepted", "CommandRejected", "CommandPending"]

let stampCanonicalTypes = (sdl: string): string =>
  sdl
  ->String.split("\n")
  ->Array.map(line => {
    let isObjectDef = canonicalTypeNames->Array.some(name => line->String.startsWith(`type ${name} `))
    let isNodeDef = line->String.startsWith("interface Node ") || line->String.startsWith("interface Node{")
    let isUnionDef = line->String.startsWith("union CommandResult ") || line->String.startsWith("union CommandResult=")
    if line->String.includes("@canonical") {
      line
    } else if isObjectDef || isNodeDef {
      // Insert before the opening brace so it composes with earlier stamps
      // (e.g. `type PageInfo @aws_cognito_user_pools @aws_iam {`).
      switch line->String.indexOfOpt("{") {
      | Some(braceIdx) =>
        let head = line->String.slice(~start=0, ~end=braceIdx)->String.trimEnd
        let tail = line->String.slice(~start=braceIdx)
        `${head} @canonical ${tail}`
      | None => line
      }
    } else if isUnionDef {
      switch line->String.indexOfOpt("=") {
      | Some(eqIdx) =>
        let head = line->String.slice(~start=0, ~end=eqIdx)->String.trimEnd
        let tail = line->String.slice(~start=eqIdx)
        `${head} @canonical ${tail}`
      | None => line
      }
    } else {
      line
    }
  })
  ->Array.join("\n")

// (The reactive push planner — planAwsPushes, the AWS counterpart of core
// GraphQL_PushPlanner — was retired with the merged-API cutover: source APIs
// are single writers, AWS composes the merged endpoint, nothing re-stitches.)
