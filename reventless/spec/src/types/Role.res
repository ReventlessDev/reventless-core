/***
A role is a job someone does — `Merchandiser`, `Fulfilment`, `Admin` — and is what
a command or a view requires. A group is how an identity provider records that a
person has one: the `groups` of a token, of a user pool, of `users.yaml`.

Plugins speak of roles. Each declares the ones it uses as a payload-less variant in
its own `src/Roles.res`, and the PPX turns `AllowRoles([Merchandiser])` into these
names. Roles are joined by name, so two plugins that both declare `Fulfilment` mean
the same role.

The platform says which group stands for which role, only where they differ; every
other role maps to the group of the same name. This module holds that mapping for
the process, so enforcement, the published access keys and the deploy check all
read one answer.
*/

/** A role's name before mapping. A string at run time, so it crosses every
    boundary a group does, but private: a plugin's role comes from its own
    `Roles.t` (the PPX checks the case, then calls `make`), and any other string
    has to pass through `make` where a reader can see it is unchecked. */
type name = private string

external make: string => name = "%identity"
external fromStringSchema: S.t<string> => S.t<name> = "%identity"

let nameSchema: S.t<name> = fromStringSchema(S.string)

/** The framework's administrator: members administer a deployment. */
let admin: name = make("Admin")

/**
The renamed roles, resolved as an explicit `setGroups`, else the environment,
else none.

The environment exists for the same reason as `REVENTLESS_ELEVATED_GROUPS`: a
deployment is two kinds of process, and a function runtime that evaluates a rule
(the SQL-backed view reads) never runs the platform root that stated the mapping.
`REVENTLESS_ROLE_GROUPS` carries only the renamed roles, as
`Merchandiser=shop-merch-team,Fulfilment=shop-ops`.
*/
@val
external _roleGroupsEnv: option<string> = "process.env.REVENTLESS_ROLE_GROUPS"

let envKey = "REVENTLESS_ROLE_GROUPS"

let explicitGroups: ref<option<array<(name, string)>>> = ref(None)

/** Set once a platform has rendered something from the mapping — an AWS admin
    API's directive is written while the platform is built. A mapping stated
    after that would leave the two disagreeing. */
let frozen = ref(false)

let freeze = () => frozen := true

/** State which group stands for which role, where the two differ. Wins over the
    environment, like every other explicit platform setting. Refused once frozen,
    rather than applying to half the deployment. */
let setGroups = (pairs: array<(name, string)>) =>
  if frozen.contents {
    JsError.throwWithMessage(
      "Role mapping stated after the platform was built — call roleGroups before Platform.Make().",
    )
  } else {
    explicitGroups := Some(pairs)
  }

let clearGroups = () => {
  explicitGroups := None
  frozen := false
}

let parseGroups = (raw: string): array<(name, string)> =>
  raw
  ->String.split(",")
  ->Array.filterMap(part =>
    switch part->String.split("=")->Array.map(String.trim) {
    | [role, group] if role != "" && group != "" => Some((make(role), group))
    | _ => None
    }
  )

/** The renamed roles in force, as `(role, group)`. */
let renamed = (): array<(name, string)> =>
  switch explicitGroups.contents {
  | Some(pairs) => pairs
  | None => _roleGroupsEnv->Option.mapOr([], parseGroups)
  }

/** The mapping as `REVENTLESS_ROLE_GROUPS` writes it, or `None` when no role is
    renamed — absent rather than empty, as for the elevated groups. */
let envValue = (): option<string> =>
  switch renamed() {
  | [] => None
  | pairs =>
    Some(pairs->Array.map(((role, group)) => `${(role :> string)}=${group}`)->Array.join(","))
  }

/** The group that stands for `role`. */
let groupOf = (role: name): string =>
  switch renamed()->Array.find(((r, _)) => r == role) {
  | Some((_, group)) => group
  | None => (role :> string)
  }

/** The group that stands for the administrator. Written into the admin API's
    directives, the elevated default and the shell's configuration. */
let adminGroup = (): string => groupOf(admin)

/**
Where the groups this deployment provides come from: the administrator group and
accounts manifest a platform finds for itself, and the groups of a user pool it
did not create, which the platform root declares.

Sources rather than values, read when the check runs: a platform states them
while its functor is applied, before the root has said how its roles map. Empty
until a platform or a root says anything, which is how a check knows whether it
has an answer to compare against.
*/
let groupSources: ref<array<unit => array<string>>> = ref([])

let provideGroupsFrom = (source: unit => array<string>) =>
  groupSources := groupSources.contents->Array.concat([source])

let provideGroups = (groups: array<string>) => provideGroupsFrom(() => groups)

let clearProvidedGroups = () => groupSources := []

/** The groups a deployment provides: every source plus every group the mapping
    names. `None` when nothing was provided — a process that is not a platform (a
    unit test, a function runtime) has no answer to give. */
let providedGroups = (): option<array<string>> =>
  switch groupSources.contents {
  | [] => None
  | sources =>
    Some(
      sources
      ->Array.flatMap(source => source())
      ->Array.concat(renamed()->Array.map(((_, group)) => group))
      ->Set.fromArray
      ->Set.values
      ->Array.fromIterator,
    )
  }
