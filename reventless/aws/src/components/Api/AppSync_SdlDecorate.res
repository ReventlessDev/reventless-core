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
// nothing. It exists so that "carries no directive" becomes a state we can
// detect and refuse at deploy time (`assertGateable`), rather than one that
// silently means "open to everyone" — which is exactly how the `@aws_auth`
// outage stayed invisible for as long as it did.
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

// Final field sweep, run at the assembly choke point on the FRAGMENT (where each
// element is one whole field, so "does it already carry a directive?" is a
// reliable question — on raw SDL text a directive placed on the following line
// would read as absent).
//
// `injectAwsAuth` only decorates fields it can pair with a schema entry, and
// several surfaces never reach it at all: the domain base document
// (`Platform_ping`), event-history queries, event-log `…_eventAppended`
// subscriptions, the upload presign/release mutations, `Platform_SetActiveRole`,
// and `geocode`. Those deployed with no directive at all — reachable by any
// authenticated Cognito caller, and invisible, since `defaultAction: ALLOW` makes
// "no directive" and "open" the same thing. Sweeping here rather than at each
// emission site means a future injected field cannot silently miss the net;
// `assertGateable` below turns a miss into a failed deploy rather than an open
// field.
//
// Idempotent, and deliberately does not second-guess gating: it only fills in
// "open to any authenticated Cognito caller", which is what an undirectived
// field already means today.
let stampUndirectivedFields = (
  fragment: Reventless.Plugin.apiSchemaFragment,
): Reventless.Plugin.apiSchemaFragment => {
  let parts = ReventlessCore.GraphQL_Stitcher.decode(fragment)
  let stamp = (field: string): string =>
    field->String.includes("@aws_") ? field : `${field}\n    ${cognitoOpenDirective}`

  ReventlessCore.GraphQL_Stitcher.encode({
    ...parts,
    mutations: parts.mutations->Array.map(stamp),
    queries: parts.queries->Array.map(stamp),
    subscriptions: parts.subscriptions->Array.map(stamp),
  })
}

// Stamp every object `type` declaration that does not already carry an auth
// directive with the group-less Cognito arm. Run on the ASSEMBLED SDL, AFTER
// stampSharedIamTypes so the shared traversal types keep their `@aws_iam` arm
// (this pass skips anything already carrying an `@aws_` directive).
//
// Types, not just fields: response shaping walks `…Connection` → `…Edge` → node
// → nested state types, so a type that cannot be traversed fails a request that
// passed the field's own gate. Entry gating stays on the fields; a type stamp
// only restores the accessibility an undirectived type has today.
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

// ── Deploy-time gate invariant ──────────────────────────────────────────────
//
// Refuse to push a schema that cannot be gated. This is the fail-closed
// property `userPoolConfig.defaultAction: DENY` would have provided at REQUEST
// time — AWS rejects DENY alongside an additional auth provider
// ("Additional authentication providers cannot be specified when setting DENY
// for top level user pool authentication type", reproduced on create and
// update alike), and every API here configures AWS_IAM unconditionally. So the
// check moves one layer earlier, into our own deploy, where nothing can veto it.
//
// Two conditions, and the second is the one that matters:
//
//   1. A root field or object type carrying NO directive AppSync honours here
//      is reachable by any authenticated Cognito caller under `ALLOW`.
//   2. ANY `@aws_auth` at all. It is the single-mode form, silently ignored on
//      a multi-auth API — so its presence means something believes it is gated
//      and is not.
//
// Condition 2 is why this is not merely "does it have a directive?". The
// original outage had `@aws_auth(cognito_groups: ["Admin"])` present on all 18
// admin fields for its entire life; a presence check would have passed it every
// single time. Only a check that knows WHICH directive the service honours
// would have failed that deploy.
let enforcedDirectives = ["@aws_cognito_user_pools", "@aws_iam"]

let hasEnforcedDirective = (s: string): bool =>
  enforcedDirectives->Array.some(d => s->String.includes(d))

let rootOperationTypes = ["Query", "Mutation", "Subscription"]

let typeDeclNameOf = (line: string): option<string> =>
  if line->String.startsWith("type ") {
    let rest = line->String.slice(~start=5, ~end=line->String.length)
    switch rest->String.search(%re("/[\s{]/")) {
    | -1 => Some(rest)
    | i => Some(rest->String.slice(~start=0, ~end=i))
    }
  } else {
    None
  }

// A root-operation field line: exactly two spaces of indent then a name. Deeper
// indents are directive continuations of the field above.
let fieldNameOf = (line: string): option<string> =>
  switch line->String.match(%re("/^ {2}(\w+)/")) {
  | Some(groups) => groups->Array.get(1)->Option.flatMap(x => x)
  | None => None
  }

// Field sweep on the ASSEMBLED SDL, for fields the fragment sweep cannot see
// because the stitcher injects them during assembly — `_noop`, the placeholder
// mutation added to keep a mutation-less schema valid, is the standing example
// and was live on three deployed APIs.
//
// Groups continuation lines into field entries the way `assertGateable` does, so
// a directive already sitting on the following line counts as present.
let stampUndirectivedRootFields = (sdl: string): string => {
  let out = []
  let currentRoot = ref(None)
  let buffer = ref([])

  let flush = () => {
    let entry = buffer.contents
    if entry->Array.length > 0 {
      entry->Array.forEach(l => out->Array.push(l))
      if !hasEnforcedDirective(entry->Array.join("\n")) {
        out->Array.push(`    ${cognitoOpenDirective}`)
      }
      buffer.contents = []
    }
  }

  sdl
  ->String.split("\n")
  ->Array.forEach(line =>
    switch typeDeclNameOf(line) {
    | Some(name) =>
      flush()
      currentRoot.contents = rootOperationTypes->Array.includes(name) ? Some(name) : None
      out->Array.push(line)
    | None =>
      if line->String.startsWith("}") {
        flush()
        currentRoot.contents = None
        out->Array.push(line)
      } else if currentRoot.contents->Option.isSome {
        switch fieldNameOf(line) {
        | Some(_) =>
          flush()
          buffer.contents = [line]
        | None =>
          if buffer.contents->Array.length > 0 {
            buffer.contents = buffer.contents->Array.concat([line])
          } else {
            out->Array.push(line)
          }
        }
      } else {
        out->Array.push(line)
      }
    }
  )
  flush()
  out->Array.join("\n")
}

let assertGateable = (sdl: string): string => {
  let bareFields = []
  let bareTypes = []
  let inertDirectives = []

  let currentRoot = ref(None)
  // (fieldName, accumulated text incl. continuation lines)
  let pending = ref(None)

  let flush = () =>
    switch pending.contents {
    | Some((name, text)) =>
      if !hasEnforcedDirective(text) {
        bareFields->Array.push(name)
      }
      pending.contents = None
    | None => ()
    }

  sdl
  ->String.split("\n")
  ->Array.forEach(line => {
    if line->String.includes("@aws_auth") {
      inertDirectives->Array.push(line->String.trim)
    }
    switch typeDeclNameOf(line) {
    | Some(name) =>
      flush()
      if !hasEnforcedDirective(line) {
        bareTypes->Array.push(name)
      }
      currentRoot.contents = rootOperationTypes->Array.includes(name) ? Some(name) : None
    | None =>
      if line->String.startsWith("}") {
        flush()
        currentRoot.contents = None
      } else if currentRoot.contents->Option.isSome {
        switch fieldNameOf(line) {
        | Some(fieldName) =>
          flush()
          pending.contents = Some((fieldName, line))
        | None =>
          switch pending.contents {
          | Some((n, text)) => pending.contents = Some((n, text ++ "\n" ++ line))
          | None => ()
          }
        }
      }
    }
  })
  flush()

  let problems = []
  if inertDirectives->Array.length > 0 {
    problems->Array.push(
      `  ${inertDirectives->Array.length->Int.toString} field(s) carry @aws_auth, which AppSync IGNORES on a\n` ++
      `  multi-auth API (this adapter always adds AWS_IAM as an additional provider).\n` ++
      `  They are gated by nothing. Emit @aws_cognito_user_pools(cognito_groups: [...])\n` ++
      `  instead — see AppSync_SdlDecorate.formatCognitoGroupsDirective.\n` ++
      `    ${inertDirectives->Array.slice(~start=0, ~end=8)->Array.join("\n    ")}`,
    )
  }
  if bareFields->Array.length > 0 {
    problems->Array.push(
      `  ${bareFields->Array.length->Int.toString} root field(s) carry no enforced auth directive, so they are\n` ++
      `  reachable by ANY authenticated Cognito caller:\n` ++
      `    ${bareFields->Array.join(", ")}`,
    )
  }
  if bareTypes->Array.length > 0 {
    problems->Array.push(
      `  ${bareTypes->Array.length->Int.toString} object type(s) carry no enforced auth directive:\n` ++
      `    ${bareTypes->Array.join(", ")}`,
    )
  }

  if problems->Array.length > 0 {
    JsError.throwWithMessage(
      `Refusing to push an AppSync schema that cannot be gated.\n\n` ++
      problems->Array.join("\n\n") ++
      `\n\nEvery field and type must carry @aws_cognito_user_pools (optionally with\n` ++
      `cognito_groups) and/or @aws_iam. The sweep in stampUndirectivedFields /\n` ++
      `stampAllTypesCognito should have covered this — a failure here means a schema\n` ++
      `reached assembly by a path that bypasses them.\n` ++
      `See docs/plans/appsync-group-authorization-unenforced.md.`,
    )
  }
  sdl
}

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
