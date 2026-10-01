/***
Whether a platform can provide every role a plugin needs.

A rule naming a role no group stands for refuses everybody it was written for, and
nothing says so until someone is refused on a deployed stack. So every role a
component's rule names, and every elevated role, must map to a group the platform
provides: the groups its identity provider reports where the platform can ask it,
else the administrator group, the accounts manifest, the role mapping and any
groups a root declares (see `Role.providedGroups`).
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

/** What to do about it depends on where the provided groups came from: a
    provider that was asked can only be given the group, while a manifest or a
    declaration can be corrected. */
let remedy = (~provided: array<string>, ~listing: option<Role.listing>): string =>
  switch listing {
  | Some({source}) =>
    let source = source->String.charAt(0)->String.toUpperCase ++ source->String.slice(~start=1)
    `  ${source} has the groups: ${provided->Array.join(", ")}.\n` ++
    `  Create the group there (provision-accounts creates the groups of the accounts ` ++ `manifest), or map the role to a group it has (Platform.roleGroups).`
  | None =>
    `  The platform provides the groups: ${provided->Array.join(", ")}.\n` ++
    `  Add an account in that group to the accounts manifest (.reventless/users.yaml), ` ++
    `map the role to a group that exists (Platform.roleGroups), or declare the groups ` ++ `of a user pool this deployment did not create (Platform.providedGroups).`
  }

let unmetMessage = (
  missing: array<need>,
  ~provided: array<string>,
  ~listing: option<Role.listing>=?,
): string =>
  `Roles this platform cannot provide — every caller would be refused:\n` ++
  missing->Array.map(n => `  ${describe(n)}`)->Array.join("\n") ++
  "\n" ++
  remedy(~provided, ~listing)

/** A declared group the provider says it does not have: the declaration is wrong,
    whether or not a plugin needs the group today. */
let contradictedMessage = (groups: array<string>, ~listing: Role.listing): string =>
  `Groups declared with Platform.providedGroups that ${listing.source} does not have: ` ++
  `${groups->Array.join(", ")}.\n` ++
  `  It has: ${listing.groups->Array.join(", ")}. Create them there or remove the declaration.`

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
    let listing = Role.listing.contents
    switch (listing, Role.declaredButMissing()) {
    | (Some(listing), groups) if groups != [] =>
      JsError.throwWithMessage(contradictedMessage(groups, ~listing))
    | _ => ()
    }
    let elevated = OwnerScope.explicitElevatedRoles.contents->Option.getOr([])
    switch unmet(needsOf(structure, ~plugin)->Array.concat(elevatedNeeds(elevated)), ~provided) {
    | [] => ()
    | missing => JsError.throwWithMessage(unmetMessage(missing, ~provided, ~listing?))
    }
  }
