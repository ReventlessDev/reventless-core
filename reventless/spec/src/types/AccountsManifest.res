/***
The accounts a deployment is operated as, as a file: `.reventless/accounts.yaml`.

Two platforms read it and they must not disagree about its shape. Locally it *is*
the identity store — the in-memory auth adapter loads it at startup. On AWS it is
the record of what was created in a Cognito pool, and `provision-accounts` both
reads it and writes back into it.

Here rather than in either platform package because a manifest that works on one
platform and silently fails on the other is the whole cost being avoided. It sits
beside [Identity] and [Role] for the same reason those do: the vocabulary
the two platforms share about who is signed in.

🚨 **The password field is a bootstrap credential, not a stored secret.** The file
is gitignored on every platform, and on AWS the passwords in it are generated per
deployment rather than committed — see `accounts.example.yaml` beside each platform.
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

`demoOwner` names the person this account plays in a demo's data, for a seed to
find it by. It exists because the name a pool accepts is not always the demo's:
a pool that signs in on an email address takes `shopper@example.com`, not
`shopper`.
*/
@schema
type entry = {
  username: string,
  password: string,
  groups: array<string>,
  userId?: string,
  demoOwner?: string,
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

/** The file's name in `.reventless/`. */
let fileName = "accounts.yaml"

/** The template each platform package keeps beside itself, committed, as the
  declaration of its cast. Both examples spell it this way and so does the local
  setup script, so it is a convention rather than a setting. */
let templateName = "accounts.example.yaml"

/** The names the file and its template had before. An app made then keeps them until it renames
  them, so both are read, with a notice. */
let oldFileName = "users.yaml"
let oldTemplateName = "users.example.yaml"

let _noticed = ref(false)

/** Says once per process that a file is read under its old name, and how to rename it. */
let noticeOldName = (path: string) =>
  if !_noticed.contents {
    _noticed := true
    Console.warn(
      `[accounts] reading ${path}: the accounts file is called ${fileName} now. Rename .reventless/${oldFileName} to .reventless/${fileName}, and ${oldTemplateName} to ${templateName}.`,
    )
  }

/** The new name's path in `dir` when it is there; else the old name's when that is there, with
  the notice; else the new name's, for a file about to be made. */
let _either = (dir: string, ~name: string, ~old: string): string => {
  let current = NodePath.join([dir, name])
  let previous = NodePath.join([dir, old])
  if !NodeFs.existsSync(current) && NodeFs.existsSync(previous) {
    noticeOldName(previous)
    previous
  } else {
    current
  }
}

/** Where both platforms keep it: beside the package the process runs from. */
let defaultPath = (): string =>
  _either(NodePath.join([NodeProcess.cwd(), ".reventless"]), ~name=fileName, ~old=oldFileName)

/** The template a platform package in `dir` keeps, under its new name or its old one. */
let templateIn = (dir: string): string => _either(dir, ~name=templateName, ~old=oldTemplateName)

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
  password?: string,
  userId?: string,
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
    let report = fills->Array.map(({index, ?password, ?userId}) => {
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

// ── Editing the cast ─────────────────────────────────────────────────────────

/**
One change to the accounts a manifest declares, addressed by username because
that is what an entry is known by on both platforms. What the local identity
provider writes; on AWS the same edits would follow a pool operation.
*/
type edit =
  | Append(entry)
  | SetGroups({username: string, groups: array<string>})
  | Remove(string)

type yamlNode

@send external createNode: (document, JSON.t) => yamlNode = "createNode"
@send external addIn: (document, array<JSON.t>, yamlNode) => unit = "addIn"
@send external setInNode: (document, array<JSON.t>, yamlNode) => unit = "setIn"
@send external deleteIn: (document, array<JSON.t>) => bool = "deleteIn"
@get external contents: document => Nullable.t<yamlNode> = "contents"
@set external setContents: (document, yamlNode) => unit = "contents"

/**
Applies edits to a manifest document, returning its new text.

Round-trips through `parseDocument` for the reason [applyFills] does: the file
carries more explanation than data. A document that is empty or only comments
becomes a sequence first. Appending a username the file already declares is
refused, because two entries for one name is a login that resolves to whichever
the loader read last; the other edits refuse a name the file does not declare,
since a change to nothing is a typo and not a no-op.
*/
let applyEdits = (yamlText: string, edits: array<edit>): result<string, string> =>
  switch switch parseYaml(yamlText) {
  | JSON.Null => Ok([])
  | _ => parseString(yamlText)
  | exception _ => parseString(yamlText)
  } {
  | Error(_) as e => e
  | Ok(initial) =>
    try {
      let doc = parseDocument(yamlText)
      if doc->contents->Nullable.isNullable {
        doc->setContents(doc->createNode(JSON.Encode.array([])))
      }
      let usernames = initial->Array.map(e => e.username)
      let indexOf = username => usernames->Array.indexOf(username)
      let failed = edits->Array.findMap(edit =>
        switch edit {
        | Append(entry) if indexOf(entry.username) >= 0 =>
          Some(`${entry.username} is already declared in the manifest`)
        | Append(entry) =>
          doc->addIn([], doc->createNode(entry->Util_Sury.toJson(entrySchema)))
          usernames->Array.push(entry.username)
          None
        | SetGroups({username, groups}) =>
          switch indexOf(username) {
          | -1 => Some(`${username} is not declared in the manifest`)
          | index =>
            doc->setInNode(
              path(index, "groups"),
              doc->createNode(groups->Array.map(JSON.Encode.string)->JSON.Encode.array),
            )
            None
          }
        | Remove(username) =>
          switch indexOf(username) {
          | -1 => Some(`${username} is not declared in the manifest`)
          | index =>
            let _ = doc->deleteIn([JSON.Number(index->Int.toFloat)])
            let _ = usernames->Array.splice(~start=index, ~remove=1, ~insert=[])
            None
          }
        }
      )
      switch failed {
      | Some(message) => Error(message)
      | None => Ok(doc->documentToString)
      }
    } catch {
    | JsExn(err) => Error(JsExn.message(err)->Option.getOr("Cannot rewrite the manifest"))
    | _ => Error("Cannot rewrite the manifest")
    }
  }

/** [applyEdits] against a file on disk, creating the file and its directory
  when there is none: the first account a provider makes should not fail for
  want of an empty file to put it in. */
let editFile = (~path as file: string, ~edits: array<edit>): result<unit, string> => {
  let text = switch NodeFs.existsSync(file) {
  | true =>
    try Ok(NodeFs.readFileSync(file)) catch {
    | JsExn(err) => Error(JsExn.message(err)->Option.getOr(`Cannot read ${file}`))
    | _ => Error(`Cannot read ${file}`)
    }
  | false => Ok("")
  }
  switch text->Result.flatMap(text => applyEdits(text, edits)) {
  | Error(_) as e => e
  | Ok(rewritten) =>
    try {
      NodeFs.mkdirSync(NodePath.dirname(file), {recursive: true})
      NodeFs.writeFileSync(file, rewritten)
      Ok()
    } catch {
    | JsExn(err) => Error(JsExn.message(err)->Option.getOr(`Cannot write ${file}`))
    | _ => Error(`Cannot write ${file}`)
    }
  }
}

// ── Finding it ───────────────────────────────────────────────────────────────

type located =
  | Declared(string)
  | SeededFrom(string, string)

let pathOf = (located: located): string =>
  switch located {
  | Declared(file) | SeededFrom(file, _) => file
  }

/**
The manifest to work from, copying the template into place when there is none.

`.reventless/` is gitignored on every platform, so a fresh clone has no manifest
and the first thing anyone met was `cp accounts.example.yaml .reventless/accounts.yaml`
— ceremony of the same kind as passing a pool id the deployment already knows.
`scripts/setup.mjs` has done this for the local platform all along; this generalises
it to any platform package, which is why it lives beside the format rather than
inside either platform's tooling.

🚨 **A named path is never seeded.** Passing one is a claim that it exists, and
copying a template over that claim would answer a typo by provisioning the wrong
cast. Only the default path is filled in.
*/
let locate = (~given: option<string>=?, ()): result<located, string> =>
  switch given {
  | Some(file) =>
    NodeFs.existsSync(file)
      ? Ok(Declared(file))
      : Error(`${file} does not exist — a named manifest is read, never created`)
  | None =>
    let file = defaultPath()
    if NodeFs.existsSync(file) {
      Ok(Declared(file))
    } else {
      let template = templateIn(NodeProcess.cwd())
      if !NodeFs.existsSync(template) {
        Error(
          `no ${file} and no ${templateName} here to start one from. Declare the accounts in .reventless/${fileName} — each entry a username, a password (empty to have one generated) and the groups it belongs to`,
        )
      } else {
        try {
          NodeFs.mkdirSync(NodePath.dirname(file), {recursive: true})
          NodeFs.cpSync(template, file, {})
          Ok(SeededFrom(file, template))
        } catch {
        | JsExn(err) =>
          Error(
            `could not copy ${NodePath.basename(template)} into place: ${JsExn.message(
                err,
              )->Option.getOr("unknown error")}`,
          )
        | _ => Error(`could not copy ${NodePath.basename(template)} into place`)
        }
      }
    }
  }

/**
The groups the accounts here belong to: the manifest's, else the template's, else
none. What a platform provides beyond its administrator group, for the check that
every role a plugin needs has a group.

Read, never seeded — this runs in a deploy or a start, which must not write the
file `locate` would. The template counts because it is the cast a fresh clone
provisions; a deploy from CI has no manifest and the same accounts to come.
*/
let declaredGroups = (): array<string> => {
  let template = templateIn(NodeProcess.cwd())
  let file = NodeFs.existsSync(defaultPath())
    ? Some(defaultPath())
    : NodeFs.existsSync(template)
    ? Some(template)
    : None
  switch file->Option.map(parseFile) {
  | Some(Ok(entries)) => entries->Array.flatMap(e => e.groups)
  | Some(Error(_)) | None => []
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
    let fills = minted->Array.mapWithIndex((password, index) => {index, ?password})
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
