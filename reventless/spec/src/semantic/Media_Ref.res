// The grammar `ImageRef` and `FileRef` share. They differ in what the value
// depicts, not in how a reference to it is written, so the rule lives once here
// rather than twice with a chance to disagree.

/** Is this an absolute web address? Schemes fold case per RFC 3986. */
let hasWebScheme = (raw: string): bool => {
  let lower = String.toLowerCase(raw)
  String.startsWith(lower, "http://") || String.startsWith(lower, "https://")
}

/**
Validate a reference to a resource the platform does not own: an `http`/`https`
URL, or an origin-relative path. `~what` names the kind in the rejection so the
message reads as the field's own.

An origin-relative path is admitted because a value may legitimately have been
minted by this platform earlier and simply not be declared as stored here —
refusing it would make the unowned types unable to hold their own history.
*/
let check = (~what: string, raw: string): result<string, string> =>
  if raw === "" {
    Error(`expected a ${what} reference, got an empty string`)
  } else if hasWebScheme(raw) {
    Ok(raw)
  } else if String.startsWith(raw, "/") && !String.startsWith(raw, "//") {
    Ok(raw)
  } else {
    Error(
      `expected an http:// or https:// address, or an origin-relative path, got ${Semantic.showString(
          raw,
        )}. A data: URI is not a ${what} reference — it inlines the bytes into the event log, permanently.`,
    )
  }
