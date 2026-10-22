// The domain's own user id, as distinct from the identity provider's handle.
//
// 🚨 **A domain event must never persist a provider-shaped id.** A reference
// written into a million events is permanent, and a log full of one provider's
// ids cannot be moved to another. What the log holds is this id; the mapping to
// the provider's handle lives in the identity capability's store.
//
// Two platforms mint and read it and must agree on both halves: the shape, so a
// seed or a test can tell a minted id from a `sub`, and the claim name, so a
// client reads its own id the same way whichever platform signed its token.

/** The claim a token carries the domain id in. Added by the Cognito pre-token
    trigger from the identity store; absent on every account created before the
    store existed, whose id stays the `sub` it always was. */
let claim = "domainUserId"

let prefix = "u_"

/** A fresh id. Prefixed so it cannot be mistaken for a bare UUID, which is what
    a Cognito `sub` is. */
let mint = (): string => prefix ++ Message.uuid()->String.replaceAll("-", "")

/** Whether an id was minted here rather than copied from a provider. */
let isMinted = (id: string): bool => id->String.startsWith(prefix)
