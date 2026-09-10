/**
Unguessable material, and a one-way function over it.

Injected rather than imported, and that is the whole point. A runtime global
would work in production and leave every consumer's *issuance* untestable: a
suite cannot assert what a flow does with a secret it cannot predict. Handing
the generator in is what lets a test pin it, exactly as an injected geocoder
lets a test pin a coordinate.

Not a portability seam like the others — every target runtime has a
cryptographic source, so this is not a provisioning choice anyone makes. It is
here because the domain must not reach for one directly, and because a test must
be able to replace it.
*/
/** What a secret is drawn from. Named rather than a charset string so a caller
    cannot ask for an alphabet nothing checks — and so the two real cases stay
    distinguishable: one is followed as a link, the other is retyped by a human
    off a screen. */
type alphabet =
  /** `0`–`9`. For a code someone reads and types back. */
  | Digits
  /** `A`–`Z`, `a`–`z`, `0`–`9`, `-`, `_`. Survives a URL untouched. */
  | UrlSafe

/** The one way this fails: nothing here is a verdict about the caller. */
type failure = Unavailable(string)

/**
The port a caller reaches a cryptographic source through.

Both members answer `result` rather than a bare string, so a platform that
provisioned nothing refuses instead of returning something weak. A token is the
one value where a silent fallback is worse than an error: it would be accepted
everywhere and guessable by anyone.
*/
type t = {
  /** `length` characters drawn uniformly from `alphabet`. */
  randomToken: (~length: int, ~alphabet: alphabet) => result<string, failure>,
  /** One-way, so a challenge can be stored without storing what would answer
        it. Deterministic: the same input always gives the same digest, which is
        what lets a presented secret be compared against a held one. */
  hash: string => result<string, failure>,
}

/** The characters each alphabet draws from. Exposed so an implementation and a
    test agree on the set rather than each spelling it. */
let characters = (alphabet: alphabet): string =>
  switch alphabet {
  | Digits => "0123456789"
  | UrlSafe => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  }

/**
A source that produces nothing, refusing both operations.

Named so a platform passing it is making a statement rather than filling in a
blank — and refusing rather than degrading, because there is no weaker token
that would be safe to hand back.
*/
let unavailable = (~reason: string): t => {
  randomToken: (~length as _, ~alphabet as _) => Error(Unavailable(reason)),
  hash: _ => Error(Unavailable(reason)),
}

/**
A source that returns what it was given, for a test that needs to know the
secret it is about to present.

Here rather than in each suite because a consumer testing issuance needs exactly
this and should not be inventing it — and because a fixed generator written per
suite is one that eventually differs from the real one's alphabet.
*/
let fixed = (~token: string, ~hash as hashOf: string => string): t => {
  randomToken: (~length as _, ~alphabet as _) => Ok(token),
  hash: input => Ok(hashOf(input)),
}
