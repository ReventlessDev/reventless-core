/***
Whether a platform can provide every role a plugin needs.

A rule naming a role no group stands for refuses everybody it was written for, and
nothing says so until someone is refused on a deployed stack. So every role a
component's rule names, and every elevated role, must map to a group the platform
provides: the administrator group it declares, the groups of its accounts
manifest, the groups the role mapping names, and any a root declares for a user
pool it did not create.
*/

type need = {
  plugin: string,
  /** The component and, for a command, the command: `Product.AddProduct`. */
  item: string,
  role: Role.name,
  group: string,
}

let needsOf = (structure: Plugin.pluginStructure, ~plugin: string): array<need> => {
  let need = (item, role) => {plugin, item, role, group: Role.groupOf(role)}
  let rolesOf = (item, roles: option<array<string>>) =>
    roles->Option.getOr([])->Array.map(role => need(item, Role.make(role)))
  let writable = (defs: array<Plugin.writableDef>) =>
    defs->Array.flatMap(w =>
      w.commands->Array.flatMap(c => rolesOf(`${w.name}.${c.name}`, c.requiredRoles))
    )
  let queryable = (defs: array<Plugin.queryableDef>) =>
    defs->Array.flatMap(q => rolesOf(q.name, q.requiredRoles))
  Array.flat([
    writable(structure.aggregates),
    writable(structure.stateChangeSlices),
    structure.inboundTranslationSlices->Array.flatMap(s => rolesOf(s.name, s.requiredRoles)),
    queryable(structure.readModels),
    queryable(structure.stateViewSlices),
  ])
}

/** The elevated roles as needs of the platform itself. */
let elevatedNeeds = (roles: array<Role.name>): array<need> =>
  roles->Array.map(role => {
    plugin: "platform",
    item: "elevated roles",
    role,
    group: Role.groupOf(role),
  })

let unmet = (needs: array<need>, ~provided: array<string>): array<need> =>
  needs->Array.filter(n => !(provided->Array.includes(n.group)))

let describe = (n: need): string => {
  let role = (n.role :> string)
  n.group == role
    ? `${n.plugin}: ${n.item} needs the role ${role}`
    : `${n.plugin}: ${n.item} needs the role ${role} (mapped to the group ${n.group})`
}

let unmetMessage = (missing: array<need>, ~provided: array<string>): string =>
  `Roles this platform cannot provide — every caller would be refused:\n` ++
  missing->Array.map(n => `  ${describe(n)}`)->Array.join("\n") ++
  `\n  The platform provides the groups: ${provided->Array.join(", ")}.\n` ++
  `  Add an account in that group to the accounts manifest (.reventless/users.yaml), ` ++
  `map the role to a group that exists (Platform.roleGroups), or declare the groups ` ++ `of a user pool this deployment did not create (Platform.providedGroups).`

/**
Refuse a plugin needing a role nobody provides, and a deployment electing a role
nobody provides. A no-op in a process where no platform stated what it provides
(`Role.providedGroups()` is `None`), which is a unit test or a function runtime
rather than a deployment.

The elevated roles are checked with every plugin rather than once by the platform
because a plugin's own stack builds no platform, and a check that runs in only one
of the two programs is skipped in the other.
*/
let check = (structure: Plugin.pluginStructure, ~plugin: string): unit =>
  switch Role.providedGroups() {
  | None => ()
  | Some(provided) =>
    let elevated = OwnerScope.explicitElevatedRoles.contents->Option.getOr([])
    switch unmet(needsOf(structure, ~plugin)->Array.concat(elevatedNeeds(elevated)), ~provided) {
    | [] => ()
    | missing => JsError.throwWithMessage(unmetMessage(missing, ~provided))
    }
  }
