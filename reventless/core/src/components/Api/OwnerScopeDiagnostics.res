// The one thing a deployment can get wrong about `@owner` without anything
// failing.
//
// `OwnerScope.elevatedGroups` defaults to `[]`, which is the safe default: it
// scopes everybody rather than exempting somebody by accident. But a deployment
// that never calls `setElevatedGroups` gets that default silently, and then
// *administrators are scoped too* — an operator opening an owner-scoped view
// sees only the rows they happen to own.
//
// Nothing errors, and it is invisible from outside: an operator whose elevated
// list is empty and an operator who genuinely owns nothing produce the identical
// empty page. That is the same unfalsifiability that makes a denied read
// indistinguishable from an empty one, arriving by a different route — so it is
// worth a line at registration rather than a support ticket later.
//
// Lives in core rather than in each adapter so the rule and its wording are
// stated once. Local and AWS both register owner-scoped views; two copies of
// this check would be two chances to word the consequence differently, or to
// fix one and not the other.

let log = Logger.fromEnv()

// Warned once per read model. Resolver registration can run more than once in a
// process (tests build several platforms; a deploy walks every plugin), and a
// warning repeated per construction is a warning people learn to scroll past.
let warned: Set.t<string> = Set.make()

/**
Warn when `view` declares an `@owner` field but no group is exempt from scoping.

`~comp` names the calling adapter so the line points at the transport it came
from. Silent when the view declares no owner, and silent once the deployment has
configured any elevated group — this is a "you probably forgot" signal, not a
policy about which groups are correct.
*/
let warnIfNoElevatedGroups = (~comp: string, ~view: string, ~ownerField: option<string>) =>
  switch ownerField {
  | Some(field) if Reventless.OwnerScope.elevatedGroups.contents->Array.length == 0 =>
    if !(warned->Set.has(view)) {
      warned->Set.add(view)
      log.warn(
        ~comp,
        `${view}: "${field}" is declared @owner, but no elevated groups are configured. ` ++
        "Every caller — administrators included — will see only their own rows. " ++
        "Call OwnerScope.setElevatedGroups([...]) before components are built.",
      )
    }
  | _ => ()
  }

/** Test seam: forget what has already been warned about. */
let resetWarnings = () => warned->Set.clear
