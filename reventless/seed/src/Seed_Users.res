// The dev accounts a seed run can log in as, read from `.reventless/users.yaml`.
//
// Both platforms keep that file beside the package the seed runs from: locally
// the in-memory auth adapter loads it at startup, and on AWS it is the record of
// what was created in the Cognito pool. Either way it already holds the
// credentials an operator would otherwise retype, so the credential prompt
// offers its entries instead of asking for a password nobody remembers.
//
// Absence is normal and silent — the caller falls back to asking. Nothing here
// throws: a missing, unreadable or malformed file yields no accounts.

@module("yaml") external parseYaml: string => JSON.t = "parse"

/** One account: what to log in as, and what to send with it. */
type user = {username: string, password: string, groups: array<string>}

let asString = (json: JSON.t): option<string> =>
  switch json {
  | String(s) => Some(s)
  | _ => None
  }

let userOf = (json: JSON.t): option<user> =>
  switch json {
  | Object(obj) =>
    switch (
      obj->Dict.get("username")->Option.flatMap(asString),
      obj->Dict.get("password")->Option.flatMap(asString),
    ) {
    | (Some(username), Some(password)) =>
      let groups = switch obj->Dict.get("groups") {
      | Some(JSON.Array(items)) => items->Array.filterMap(asString)
      | _ => []
      }
      Some({username, password, groups})
    | _ => None
    }
  | _ => None
  }

/**
 * The accounts a users.yaml document defines, in the order it defines them —
 * the order is what makes "the first one" a stable default.
 *
 * An entry without both a username and a password is skipped rather than
 * rejected: the file is hand-maintained, and one incomplete entry should not
 * cost the operator the rest of the list.
 */
let parseString = (yamlText: string): array<user> => {
  let doc = try parseYaml(yamlText) catch {
  | _ => JSON.Null
  }
  switch doc {
  | Array(items) => items->Array.filterMap(userOf)
  | _ => []
  }
}

/** Where the file lives for the platform being seeded — the seed runs from that
    package's directory, which is the same cwd the local auth adapter reads. */
let defaultPath = (): string => NodePath.join([NodeProcess.cwd(), ".reventless", "users.yaml"])

/**
 * The accounts on disk, with the path they came from. `None` when there is no
 * readable file with at least one usable account, which the caller reads as
 * "ask for credentials instead".
 */
let load = (~path: option<string>=?): option<(string, array<user>)> => {
  let file = path->Option.getOr(defaultPath())
  let users = try {
    NodeFs.existsSync(file) ? parseString(NodeFs.readFileSync(file)) : []
  } catch {
  | _ => []
  }
  users->Array.length == 0 ? None : Some((file, users))
}

/** Menu label: the username, plus whatever groups the file records for it. */
let label = (u: user): string =>
  u.groups->Array.length == 0 ? u.username : `${u.username}  [${u.groups->Array.join(", ")}]`
