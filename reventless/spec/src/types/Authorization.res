// Provider-agnostic authorization rules. Evaluated against the
// `Identity.t` resolved by an `Auth_Adapter.Provider.authenticate` call.
//
// A spec writes its rules over its plugin's own roles, `rule<Roles.t>`, so a
// misspelled role does not compile. The framework reads them as `permission`,
// the same rule over role names, which `Role.groupOf` maps to the group that
// stands for each role in this deployment.

type rule<'role> =
  | AllowRoles(array<'role>)
  | AllowAuthenticated
  | AllowAnonymous
  | DenyAll

/** A rule over role names: what the framework compares, maps and publishes. */
type permission = rule<Role.name>

/** A spec's rule as the framework reads it. Each role must be a case without a
    payload, which is its name at run time; anything else is refused. */
@module("./authorizationNamed.mjs")
external named: rule<'role> => permission = "named"

/** The roles a rule names, before mapping. */
let rolesOf = (rule: permission): array<Role.name> =>
  switch rule {
  | AllowRoles(roles) => roles
  | AllowAuthenticated | AllowAnonymous | DenyAll => []
  }

/** The groups a rule admits, mapped. */
let groupsOf = (rule: permission): array<string> => rule->rolesOf->Array.map(Role.groupOf)

/**
Whether a rule admits a caller, given whether they are signed in and which roles
they hold. The one decision both `isAllowed` and a GWT scenario make, so the two
cannot read a rule differently.
*/
let admits = (rule: permission, ~signedIn: bool, ~holds: Role.name => bool): bool =>
  switch rule {
  | DenyAll => false
  | AllowAnonymous => true
  | AllowAuthenticated => signedIn
  | AllowRoles(roles) => roles->Array.some(holds)
  }

/** The rule a caller satisfies when they satisfy any of `rules`; `None` for none. */
let anyOf = (rules: array<permission>): option<permission> =>
  if rules->Array.length == 0 {
    None
  } else if rules->Array.some(r => r == AllowAnonymous) {
    Some(AllowAnonymous)
  } else if rules->Array.some(r => r == AllowAuthenticated) {
    Some(AllowAuthenticated)
  } else {
    switch rules->Array.flatMap(rolesOf)->Set.fromArray->Set.values->Array.fromIterator {
    | [] => Some(DenyAll)
    | roles => Some(AllowRoles(roles))
    }
  }

let isAllowed = (rule: permission, identity: Identity.t): bool =>
  admits(rule, ~signedIn=identity.userId !== "anonymous", ~holds=role =>
    identity.groups->Array.includes(Role.groupOf(role))
  )
