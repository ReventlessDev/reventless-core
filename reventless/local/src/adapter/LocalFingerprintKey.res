// The local platform's fingerprint key, the one `secrets.fingerprint` is keyed by.
//
// Resolved once, on first use, from the same ladder as the local token secret:
//
//   1. `REVENTLESS_FINGERPRINT_KEY` — an explicit pin, for a test or a developer
//      who wants to state it.
//   2. `.reventless/fingerprint-key` beside the platform's other local state,
//      minted on the first run that finds the directory and reused after. A
//      fingerprint is a tag in the event log, so a key that changed on restart
//      would lose every registration a SQLite store kept.
//   3. A random 32 bytes, per process, for a run with no `.reventless/`.
//
// The directory is used, never created, for the reason `LocalAuth` gives: its
// presence is what tells a platform someone develops against from a unit test.

let fileName = "fingerprint-key"

let mint = (): string => NodeCrypto.randomBytes(32)->NodeCrypto.bufferToString("hex")

let readAt = (path: string): option<string> =>
  switch NodeFs.readFileSync(path) {
  | contents
    if String.length(String.trim(contents)) >=
    ReventlessCore.Secrets_Node_Backend.minimumFingerprintKeyLength =>
    Some(String.trim(contents))
  | _ => None
  | exception _ => None
  }

/** The ladder, against a stated directory, so a test can walk it without a
    `.reventless/` in its own working directory. */
let resolveIn = (~dir: string): string =>
  switch NodeProcess.env->Dict.get(ReventlessCore.Secrets_Node_Backend.fingerprintKeyVariable) {
  | Some(key) if key != "" => key
  | _ =>
    if NodeFs.existsSync(dir) {
      let path = NodePath.join([dir, fileName])
      switch readAt(path) {
      | Some(persisted) => persisted
      | None =>
        let minted = mint()
        switch NodeFs.writeFileSync(path, minted) {
        | () => ()
        | exception _ => ()
        }
        minted
      }
    } else {
      mint()
    }
  }

let resolved: ref<option<string>> = ref(None)

/** The key, resolved on first use and kept for the process. */
let get = (): option<string> =>
  switch resolved.contents {
  | Some(key) => Some(key)
  | None =>
    let key = resolveIn(~dir=NodePath.join([NodeProcess.cwd(), ".reventless"]))
    resolved := Some(key)
    Some(key)
  }

/** Forget the resolved key, for a test that pins another. */
let reset = () => resolved := None
