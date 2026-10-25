// What the host shell needs to let a visitor create an account, read off the
// plugin structures rather than written by hand: the mutation that starts a
// registration, the one that completes it, and the groups a visitor may sign up
// for. Absent when no plugin marks both doors, so a deployment without
// self-registration writes the same `config.json` it always did.

let configKey = "selfRegistration"

type config = {
  start: string,
  complete: string,
  /** The groups of the roles declared self-service, as the deployment maps them. */
  roles: array<string>,
}

let doorField = (
  structures: array<(string, Reventless.Plugin.pluginStructure)>,
  part: Reventless.Admission.door,
): option<string> =>
  structures->Array.findMap(((plugin, s)) =>
    s.admissionDoors
    ->Option.getOr([])
    ->Array.find(d => d.part == Reventless.Admission.doorName(part))
    ->Option.map(d => Api_Naming.sliceMutationField(~plugin, ~slice=d.component))
  )

let selfServiceGroups = (structures: array<(string, Reventless.Plugin.pluginStructure)>) =>
  structures->Array.flatMap(((_, s)) =>
    switch s.admission->Option.map(Reventless.Admission.fromDefs) {
    | Some(Ok(table)) => table->Reventless.Admission.selfService->Array.map(Reventless.Role.groupOf)
    | Some(Error(_)) | None => []
    }
  )

/** The configuration, where a deployment has a door that starts and one that
    completes a registration. */
let fromStructures = (structures: array<(string, Reventless.Plugin.pluginStructure)>): option<
  config,
> =>
  switch (doorField(structures, Start), doorField(structures, Complete)) {
  | (Some(start), Some(complete)) => Some({start, complete, roles: selfServiceGroups(structures)})
  | _ => None
  }

let toJson = (c: config): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      ("start", JSON.Encode.string(c.start)),
      ("complete", JSON.Encode.string(c.complete)),
      ("roles", c.roles->Array.map(JSON.Encode.string)->JSON.Encode.array),
    ]),
  )

let configEntry = (c: config): (string, JSON.t) => (configKey, toJson(c))
