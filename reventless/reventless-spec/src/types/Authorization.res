// Provider-agnostic authorization rules. Evaluated against the
// `Identity.t` resolved by an `Auth_Adapter.Provider.authenticate` call.
//
// `array<string>` for groups (not a parameterised variant) keeps the
// framework decoupled from any application's specific group set —
// applications can define their own typed `group` variant and convert via
// a thin helper, see docs/analysis/authentication-authorization.md §4.2.

@schema
type permission =
  | AllowGroups(array<string>)
  | AllowAuthenticated
  | AllowAnonymous
  | DenyAll

let isAllowed = (rule: permission, identity: Identity.t): bool =>
  switch rule {
  | DenyAll => false
  | AllowAnonymous => true
  | AllowAuthenticated => identity.userId !== "anonymous"
  | AllowGroups(groups) =>
    groups->Array.some(group => identity.groups->Array.includes(group))
  }
