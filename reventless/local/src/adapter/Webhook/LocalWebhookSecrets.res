// The secrets the local platform's signed webhook doors are checked with, so a door works without
// anyone exporting one first, and a caller on this machine (a stand-in, a tool) can sign as the
// real sender will.
//
// Per secret name, the same ladder as the fingerprint key:
//
//   1. `REVENTLESS_WEBHOOK_SECRET_<NAME>` — an explicit pin, left as it is.
//   2. `.reventless/webhook-secrets.json` beside the platform's other local state, minted on the
//      first run (which makes the directory, as the registry entry does) and reused after, so a
//      caller started earlier still signs right.
//   3. A random 32 bytes, per process, when the directory cannot be made.
//
// The value it settles on is put into the variable the door reads, so the check stays the one AWS
// runs. The file holds no real secret: it is the local platform's, and is never committed.

let fileName = "webhook-secrets.json"

let mint = (): string => NodeCrypto.randomBytes(32)->NodeCrypto.bufferToString("hex")

/** A door as a caller needs it: where to post, and the name of the secret it signs with. */
@schema
type door = {
  path: string,
  slice: string,
  method: string,
  // Absent: an open door, which takes an unsigned post.
  secret?: string,
  // The header the signature goes in, and what precedes it there (`sha256=`).
  header?: string,
  prefix?: string,
  timestampHeader?: string,
}

@schema
type file = {
  doors: array<door>,
  secrets: dict<string>,
}

let doorOf = (r: ReventlessCore.InboundTranslationSlice_Webhook.route): door =>
  switch r.auth {
  | Open => {path: r.path, slice: r.slice, method: r.method}
  | SignedBody({secret, header, ?prefix, ?timestampHeader}) => {
      path: r.path,
      slice: r.slice,
      method: r.method,
      secret,
      header,
      ?prefix,
      ?timestampHeader,
    }
  }

let readAt = (path: string): dict<string> =>
  try {
    (
      path->NodeFs.readFileSync->JSON.parseOrThrow->Reventless.Util_Sury.fromJson(fileSchema)
    ).secrets
  } catch {
  | _ => Dict.make()
  }

/** Settles a secret for every signed door, against a stated directory, and returns the file it
    wrote there, if it could. */
let ensureIn = (~dir: string): option<string> => {
  let path = NodePath.join([dir, fileName])
  // Made here rather than waited for: the registry entry makes it a moment later, and a fresh
  // app's first start would otherwise publish no file.
  try NodeFs.mkdirSync(dir, {recursive: true}) catch {
  | _ => ()
  }
  let kept = NodeFs.existsSync(dir) ? readAt(path) : Dict.make()
  let secrets = Dict.make()
  LocalWebhookRegistry.signedSecrets()->Array.forEach(name => {
    let key = ReventlessCore.InboundTranslationSlice_Webhook.secretEnvKey(name)
    let value = switch NodeProcess.env->Dict.get(key) {
    | Some(pinned) if pinned != "" => pinned
    | _ =>
      let value = kept->Dict.get(name)->Option.getOr(mint())
      NodeProcess.env->Dict.set(key, value)
      value
    }
    secrets->Dict.set(name, value)
  })
  switch NodeFs.existsSync(dir) {
  | false => None
  | true =>
    let doors = LocalWebhookRegistry.doors()->Array.map(doorOf)
    switch NodeFs.writeFileSync(
      path,
      {doors, secrets}->Reventless.Util_Sury.toJson(fileSchema)->JSON.stringify(~space=2),
    ) {
    | () => Some(path)
    | exception _ => None
    }
  }
}

/** Settles the secrets in the working directory's `.reventless/`. */
let ensure = (): option<string> => ensureIn(~dir=NodePath.join([NodeProcess.cwd(), ".reventless"]))
