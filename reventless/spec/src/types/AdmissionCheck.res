/***
Whether a deployment can honor what its plugins declare about admission.

A role declared self-service with no door for visitors, or by invitation with
nothing that invites, is a declaration nothing honors, and nobody would know
until the first person could not get in. So the declarations are read against
what the platform has — its doors, the capabilities it provisions, which groups
are elevated — and a deployment that cannot honor one is refused at start, as it
is refused a role no group stands for.
*/

type problem = {plugin: string, role: string, why: string}

let describe = (p: problem) => `${p.plugin}: ${p.role} ${p.why}`

let hasDoor = (doors: array<Admission.doorDef>, part: Admission.door) =>
  doors->Array.some(d => d.part == Admission.doorName(part))

/**
Every declaration this platform cannot honor. `anonymousDoors` says whether the
platform admits callers who are not signed in at all — a deployed platform does
not yet — and `provisioned` is what it provides to slices.
*/
let problems = (
  ~structures: array<(string, Plugin.pluginStructure)>,
  ~provisioned: array<CapabilityNeed.t>,
  ~elevatedGroups: array<string>,
  ~adminGroup: string,
  ~anonymousDoors: bool,
): array<problem> => {
  let anyInvites =
    structures->Array.some(((_, s)) => hasDoor(s.admissionDoors->Option.getOr([]), Invite))
  let missingCapabilities =
    [CapabilityNeed.Messaging, CapabilityNeed.IdentityProvider]
    ->Array.filter(need => !(provisioned->Array.includes(need)))
    ->Array.map(CapabilityNeed.toString)
  structures->Array.flatMap(((plugin, structure)) =>
    switch structure.admission {
    | None => []
    | Some(defs) =>
      let doors = structure.admissionDoors->Option.getOr([])
      switch Admission.fromDefs(defs) {
      | Error(why) => [{plugin, role: "admission", why: `cannot be read: ${why}`}]
      | Ok(table) =>
        table->Array.flatMap(({role, strategy}) => {
          let roleName = (role :> string)
          let problem = why => {plugin, role: roleName, why}
          let spelled = switch strategy {
          | SelfService => "self-service"
          | Invitation(_) => "by invitation"
          | Provisioned => "provisioned"
          }
          let needsCapabilities = () =>
            switch missingCapabilities {
            | [] => []
            | missing => [
                problem(
                  `is ${spelled}, but this platform provisions no ${missing->Array.join(
                      " and no ",
                    )}`,
                ),
              ]
            }
          switch strategy {
          | Provisioned => []
          | SelfService =>
            let group = Role.groupOf(role)
            Array.flat([
              group == adminGroup || elevatedGroups->Array.includes(group)
                ? [
                    problem(
                      `is self-service, but its group ${group} is elevated: anyone could sign up as an operator`,
                    ),
                  ]
                : [],
              anonymousDoors
                ? []
                : [
                    problem(
                      "is self-service, but this platform has no door for callers who are not signed in",
                    ),
                  ],
              hasDoor(doors, Start) && hasDoor(doors, Complete)
                ? []
                : [
                    problem(
                      `is self-service, but no door in ${plugin} starts and completes a registration`,
                    ),
                  ],
              needsCapabilities(),
            ])
          | Invitation(_) =>
            Array.flat([
              anyInvites
                ? []
                : [
                    problem(
                      "is by invitation, but nothing in this deployment provides invitations",
                    ),
                  ],
              needsCapabilities(),
            ])
          }
        })
      }
    }
  )
}

let message = (problems: array<problem>): string =>
  `Admission this platform cannot honor — the people it is for could not get in:\n` ++
  problems->Array.map(p => `  ${describe(p)}`)->Array.join("\n")

/** Refuse a deployment whose admission declarations nothing honors. */
let check = (~structures, ~provisioned, ~elevatedGroups, ~adminGroup, ~anonymousDoors): unit =>
  switch problems(~structures, ~provisioned, ~elevatedGroups, ~adminGroup, ~anonymousDoors) {
  | [] => ()
  | found => JsError.throwWithMessage(message(found))
  }
