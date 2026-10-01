// The administrator group as the host shell reads it from `config.json`: the
// group the platform gates its admin API on, from the same role-to-group
// resolution as the server, so the two cannot disagree. Written only where the
// deployment maps the administrator role away from its own name; the shell
// reads an absent key as `Admin`, so a default deployment's file is unchanged.

let configKey = "adminGroup"

let configEntry = (): option<(string, JSON.t)> => {
  let group = Reventless.Role.adminGroup()
  group == (Reventless.Role.admin :> string) ? None : Some((configKey, JSON.Encode.string(group)))
}
