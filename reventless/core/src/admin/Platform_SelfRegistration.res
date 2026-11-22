// What the host shell needs to let a visitor create an account, read off the
// plugin structures rather than written by hand: the mutation that starts a
// registration, the one that completes it, the groups a visitor may sign up
// for, and the query that says which of them are open right now. Absent when no
// plugin marks both doors, so a deployment without self-registration writes the
// same `config.json` it always did.

let configKey = "selfRegistration"

type policy = {@as("open") open_: string, close: string}

type config = {
  start: string,
  complete: string,
  /** The groups of the roles declared self-service, as the deployment maps them. */
  roles: array<string>,
  /** The list query of the view saying which roles are open, where a plugin marks one. */
  openRoles?: string,
  /** What a role is while nothing is recorded about it, and once a window has
      passed: `open` or `closed`, as the platform starts. */
  initially: string,
  /** The mutations an administrator opens and closes a role with, where a plugin
      marks its policy. */
  policy?: policy,
}

let marked = (
  structures: array<(string, Reventless.Plugin.pluginStructure)>,
  part: Reventless.Admission.door,
): option<(string, Reventless.Admission.doorDef)> =>
  structures->Array.findMap(((plugin, s)) =>
    s.admissionDoors
    ->Option.getOr([])
    ->Array.find(d => d.part == Reventless.Admission.doorName(part))
    ->Option.map(d => (plugin, d))
  )

let doorField = (
  structures: array<(string, Reventless.Plugin.pluginStructure)>,
  part: Reventless.Admission.door,
): option<string> =>
  marked(structures, part)->Option.map(((plugin, d)) =>
    Api_Naming.sliceMutationField(~plugin, ~slice=d.component)
  )

let openRolesField = (structures: array<(string, Reventless.Plugin.pluginStructure)>): option<
  string,
> =>
  marked(structures, OpenRoles)->Option.map(((plugin, d)) =>
    // The view's own published field, so a `@plural` on it is honored.
    structures
    ->Array.findMap(((p, s)) => p == plugin ? Some(s) : None)
    ->Option.flatMap(s => s.stateViewSlices->Array.find(v => v.name == d.component))
    ->Option.mapOr(
      Api_Naming.queryFieldNamesForStateView(~plugin, ~viewName=d.component).listFieldName,
      v => v.queryField,
    )
  )

let selfServiceGroups = (structures: array<(string, Reventless.Plugin.pluginStructure)>) =>
  structures->Array.flatMap(((_, s)) =>
    switch s.admission->Option.map(Reventless.Admission.fromDefs) {
    | Some(Ok(table)) => table->Reventless.Admission.selfService->Array.map(Reventless.Role.groupOf)
    | Some(Error(_)) | None => []
    }
  )

/** The marked policy's two mutations: the command that opens (its name starts
    with `Open`) and the one that closes (`Close`). None unless it has both. */
let policyFields = (structures: array<(string, Reventless.Plugin.pluginStructure)>): option<
  policy,
> =>
  marked(structures, Policy)->Option.flatMap(((plugin, d)) => {
    let commands =
      structures
      ->Array.findMap(((p, s)) => p == plugin ? Some(s) : None)
      ->Option.flatMap(s => s.stateChangeSlices->Array.find(c => c.name == d.component))
      ->Option.mapOr([], c => c.commands)
    let field = prefix =>
      commands->Array.find(c => c.name->String.startsWith(prefix))->Option.map(c => c.mutationField)
    switch (field("Open"), field("Close")) {
    | (Some(open_), Some(close)) => Some({open_, close})
    | _ => None
    }
  })

/** The configuration, where a deployment has a door that starts and one that
    completes a registration, on a platform whose self-service roles start
    `initially`. */
let fromStructures = (
  structures: array<(string, Reventless.Plugin.pluginStructure)>,
  ~initially: Reventless.Admission.initially,
): option<config> =>
  switch (doorField(structures, Start), doorField(structures, Complete)) {
  | (Some(start), Some(complete)) =>
    Some({
      start,
      complete,
      roles: selfServiceGroups(structures),
      openRoles: ?openRolesField(structures),
      initially: Reventless.Admission.initiallyName(initially),
      policy: ?policyFields(structures),
    })
  | _ => None
  }

let toJson = (c: config): JSON.t => {
  let entries = Dict.fromArray([
    ("start", JSON.Encode.string(c.start)),
    ("complete", JSON.Encode.string(c.complete)),
    ("roles", c.roles->Array.map(JSON.Encode.string)->JSON.Encode.array),
  ])
  c.openRoles->Option.forEach(q => entries->Dict.set("openRoles", JSON.Encode.string(q)))
  entries->Dict.set("initially", JSON.Encode.string(c.initially))
  c.policy->Option.forEach(p =>
    entries->Dict.set(
      "policy",
      JSON.Encode.object(
        Dict.fromArray([
          ("open", JSON.Encode.string(p.open_)),
          ("close", JSON.Encode.string(p.close)),
        ]),
      ),
    )
  )
  JSON.Encode.object(entries)
}

let configEntry = (c: config): (string, JSON.t) => (configKey, toJson(c))
