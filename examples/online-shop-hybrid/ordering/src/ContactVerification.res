/**
Proving that a person controls a contact address.

One secret, expiring, non-replayable, and dropped if the address changes
underneath it. What a settled proof *entitles* is the host's business and
deliberately absent: that is the part that would not survive a host swap.
*/
/** An address, not a channel. Narrower than `Messaging.recipient` on purpose —
    a push token is not a claim anyone makes, so the wrong subject is not
    constructible. */
type contact =
  | ByEmail(Reventless.Email.t)
  | ByPhone(Reventless.Phone.t)

/** Which channels an address is reachable over. One-to-many, which is why
    address and channel stay separate types; intersected at runtime with the
    channels the deployment's provider publishes. */
let channelsFor = (contact: contact): array<Reventless.Messaging.channel> =>
  switch contact {
  | ByEmail(_) => [Email]
  | ByPhone(_) => [Sms]
  }

/** Total, because being addressable is what makes something a subject. */
let toRecipient = (contact: contact): Reventless.Messaging.recipient =>
  switch contact {
  | ByEmail(email) => ToEmail(email)
  | ByPhone(phone) => ToSms(phone)
  }

/** Why the proof is being asked for. The same machinery serves a registration, a
    contact change, an invitation and a recovery; without this the next four
    consumers each rebuild it. */
type purpose =
  | Registration
  | ContactChange
  | Invitation
  | Recovery
  | Custom(string)

type subject = {contact: contact, purpose: purpose}

/** How a challenge ended. `Superseded` is the address changing while it was
    open — a fact about the host, not about the person. */
type outcome =
  | Verified
  | Expired
  | Superseded
  | Abandoned

/** What a secret is drawn from. A link is followed and a code is typed off a
    screen, so the two cannot share an alphabet. */
type alphabet =
  | Digits
  | UrlSafe

/** Keyed by channel — not globally, and not by contact. A 32-character link with
    a 24-hour window is right for email and unusable over SMS, where a human
    retypes the proof. Keying by contact would look identical today and quietly
    hard-code one channel per address. */
type policy = {
  tokenTtl: Reventless.Duration.t,
  maxAttempts: int,
  resendCooldown: Reventless.Duration.t,
  proofLength: int,
  proofAlphabet: alphabet,
}

/** A day to act on, and a long secret because nobody types it. */
let emailPolicy: policy = {
  tokenTtl: 86400,
  maxAttempts: 5,
  resendCooldown: 60,
  proofLength: 32,
  proofAlphabet: UrlSafe,
}

/** Short-lived and short, because it is read off one screen and typed into
    another — and fewer attempts, because six digits is a guessable space. */
let smsPolicy: policy = {
  tokenTtl: 600,
  maxAttempts: 3,
  resendCooldown: 60,
  proofLength: 6,
  proofAlphabet: Digits,
}

/**
`None` for `Push`, and that is structural rather than unfinished.

A push token is issued to one app install and relayed over an already
authenticated session, so a challenge echoed back proves only what registering
the token proved. Push presupposes the session it would be bootstrapping. An
arm that merely had no policy yet would invite someone to supply one.
*/
let policyFor = (channel: Reventless.Messaging.channel): option<policy> =>
  switch channel {
  | Email => Some(emailPolicy)
  | Sms => Some(smsPolicy)
  | Push => None
  }
