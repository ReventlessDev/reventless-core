/***
The accounts a deployment is operated as, as a file: `.reventless/users.yaml`.

Two platforms read it and they must not disagree about its shape. Locally it *is*
the identity store — the in-memory auth adapter loads it at startup. On AWS it is
the record of what was created in a Cognito pool, and `provision-accounts` both
reads it and writes back into it.

Here rather than in either platform package because a manifest that works on one
platform and silently fails on the other is the whole cost being avoided. It sits
beside [Identity] and [AdminGroup] for the same reason those do: the vocabulary
the two platforms share about who is signed in.

🚨 **The password field is a bootstrap credential, not a stored secret.** The file
is gitignored on every platform, and on AWS the passwords in it are generated per
deployment rather than committed — see `users.example.yaml` beside each platform.
*/

/**
One account. `groups` is required (`[]` for an unprivileged account).

`password` is required but may be empty: an AWS manifest is written before the
accounts exist, and `provision-accounts` fills the empty ones in. An empty
password authenticates nowhere, which is the correct reading of "not yet
provisioned" on both platforms.

`userId` is what the platform stamps on rows this account writes. Locally it
defaults to the username; on AWS it is the `sub` the pool minted, so it can only
be filled in after the account exists.
*/
@schema
type entry = {
  username: string,
  password: string,
  groups: array<string>,
  userId?: string,
}

let entriesSchema = S.array(entrySchema)

@module("yaml") external parseYaml: string => JSON.t = "parse"

/** Parses a manifest document. Strict: a malformed entry refuses the whole file
  rather than being skipped, because on both platforms a silently dropped account
  reads as a login that stopped working for no stated reason. */
let parseString = (yamlText: string): result<array<entry>, string> =>
  try {
    Ok(S.parseOrThrow(parseYaml(yamlText), ~to=entriesSchema))
  } catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr("YAML parse error"))
  | _ => Error("YAML parse error")
  }

let parseFile = (path: string): result<array<entry>, string> =>
  try {
    parseString(NodeFs.readFileSync(path))
  } catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr(`Cannot read ${path}`))
  | _ => Error(`Cannot read ${path}`)
  }

/** Where both platforms keep it: beside the package the process runs from. */
let defaultPath = (): string => NodePath.join([NodeProcess.cwd(), ".reventless", "users.yaml"])

// ── Writing back ─────────────────────────────────────────────────────────────

/**
A value provisioning learned and the file does not know yet, addressed by the
entry's position in the document.

`password` is written **only into an empty field** — see [applyFills]. `userId` is
written whenever it differs, because on AWS the pool mints it and the file is only
ever a copy: a stale one is not a documentation slip but rows keyed to an id
nobody holds.
*/
type fill = {
  index: int,
  password: option<string>,
  userId: option<string>,
}

/** What a fill actually did, so the caller can report it rather than guess. */
type filled = {
  index: int,
  passwordWritten: bool,
  userIdWritten: bool,
}

type document

@module("yaml") external parseDocument: string => document = "parseDocument"
@send external getIn: (document, array<JSON.t>) => JSON.t = "getIn"
@send external setIn: (document, array<JSON.t>, JSON.t) => unit = "setIn"
@send external documentToString: document => string = "toString"

let path = (index: int, field: string): array<JSON.t> => [
  JSON.Number(index->Int.toFloat),
  JSON.String(field),
]

let currentString = (doc: document, index: int, field: string): option<string> =>
  switch doc->getIn(path(index, field)) {
  | JSON.String(s) => Some(s)
  | _ => None
  }

/**
Applies fills to a manifest document, returning the document's new text.

🚨 **Round-trips through `parseDocument` rather than re-serializing the parsed
entries**, so every comment survives. Both manifests carry more explanation than
data — which account is elevated and why, which pool these subs came from — and a
tool that silently deleted it would cost more than it saved.

🚨 **A password already in the file is never replaced.** A second run is the
normal case (an operator adding one account to four), and the failure mode of the
obvious implementation is overwriting a credential somebody is signed in with.
Empty means empty or whitespace; anything else is somebody's choice.
*/
let applyFills = (yamlText: string, fills: array<fill>): result<(string, array<filled>), string> =>
  try {
    let doc = parseDocument(yamlText)
    let report = fills->Array.map(({index, password, userId}) => {
      let passwordWritten = switch password {
      | Some(generated)
        if doc->currentString(index, "password")->Option.getOr("")->String.trim == "" =>
        doc->setIn(path(index, "password"), JSON.String(generated))
        true
      | _ => false
      }
      let userIdWritten = switch userId {
      | Some(minted) if doc->currentString(index, "userId") != Some(minted) =>
        doc->setIn(path(index, "userId"), JSON.String(minted))
        true
      | _ => false
      }
      {index, passwordWritten, userIdWritten}
    })
    Ok((doc->documentToString, report))
  } catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr("Cannot rewrite the manifest"))
  | _ => Error("Cannot rewrite the manifest")
  }

/** [applyFills] against a file on disk. Reads, rewrites, writes — and writes
  nothing at all when no fill applied, so a fully-provisioned manifest keeps its
  mtime and a second run is visibly a no-op. */
let fillFile = (~path as file: string, ~fills: array<fill>): result<array<filled>, string> =>
  switch try Ok(NodeFs.readFileSync(file)) catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr(`Cannot read ${file}`))
  | _ => Error(`Cannot read ${file}`)
  } {
  | Error(_) as e => e
  | Ok(text) =>
    switch applyFills(text, fills) {
    | Error(_) as e => e
    | Ok((_, report)) if !(report->Array.some(r => r.passwordWritten || r.userIdWritten)) =>
      Ok(report)
    | Ok((rewritten, report)) =>
      try {
        NodeFs.writeFileSync(file, rewritten)
        Ok(report)
      } catch {
      | JsExn(err) => Error(JsExn.message(err)->Option.getOr(`Cannot write ${file}`))
      | _ => Error(`Cannot write ${file}`)
      }
    }
  }

// ── Preparing ────────────────────────────────────────────────────────────────

/** One account after preparation: what the file now declares, and whether this
  run is what put the password there. */
type prepared = {
  entry: entry,
  passwordGenerated: bool,
}

/**
Validates a manifest and fills in what it leaves blank.

🚨 **This is the whole of provisioning on the local platform, and the first half
of it on AWS.** Locally the manifest *is* the user store — the auth adapter
hydrates from it at startup — so once every account has a password there is
nothing left to create. On AWS the accounts still have to be made in a pool, and
that half is Cognito's, in `reventless/aws`.

Which is why it lives here and takes no client, no region and no credentials: a
developer with an empty password field can run it on a laptop that has never held
an AWS key.

The passwords it mints are written straight back, because a generated credential
that is only printed is one the seed client cannot read.
*/
let prepare = (~path as file: string): result<array<prepared>, string> =>
  switch parseFile(file) {
  | Error(_) as e => e
  | Ok(entries) =>
    let minted =
      entries->Array.map(entry =>
        entry.password->String.trim == "" ? Some(Util_Password.generate()) : None
      )
    let fills = minted->Array.mapWithIndex((password, index) => {index, password, userId: None})
    switch fillFile(~path=file, ~fills) {
    | Error(_) as e => e
    | Ok(report) =>
      Ok(
        entries->Array.mapWithIndex((entry, index) => {
          let written = report->Array.get(index)->Option.mapOr(false, r => r.passwordWritten)
          switch (written, minted->Array.getUnsafe(index)) {
          | (true, Some(password)) => {entry: {...entry, password}, passwordGenerated: true}
          | _ => {entry, passwordGenerated: false}
          }
        }),
      )
    }
  }
