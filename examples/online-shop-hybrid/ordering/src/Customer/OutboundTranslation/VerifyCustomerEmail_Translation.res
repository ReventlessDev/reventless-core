@@reventless.translation

module V = ContactVerification

// Keyed by entity *and* address, so a later change is new work rather than work
// already done — the same keying the geocoding slice uses, and for the same
// reason. `~sourceId` is the entity id, which an aggregate's payload omits.
let collect = (event, ~sourceId) =>
  switch event {
  | Registered({email}) => [(`${sourceId}:${email}`, {customerId: sourceId, email})]
  | EmailUpdated({email}) => [(`${sourceId}:${email}`, {customerId: sourceId, email})]
  }

let policy = V.emailPolicy

let body = (~token) =>
  `Confirm this address by entering ${token}. It expires in ${policy.tokenTtl->Reventless.Duration.format}.`

/**
Draw a secret, send it, and open a challenge against its hash.

The order is deliberate: the message goes first, so the hash that is recorded is
always the one that was actually delivered. Issuing first and failing to send
would leave a challenge nobody can answer, and the ledger would then refuse to
open a second one for the same address until the first lapsed.

The clock is read here rather than in `decide`, which is why the instant travels
on the command. A translation is the edge and may be non-deterministic; a
decision is replayed and may not.
*/
let translate = async (_id, item: outboundItem, ~capabilities: Reventless.Capabilities.t) => {
  let contact = V.ByEmail(item.email)
  switch capabilities.secrets.randomToken(
    ~length=policy.proofLength,
    ~alphabet=policy.proofAlphabet,
  ) {
  // No secret source, so nothing can be proven here. Retryable rather than a
  // verdict: the address is fine, the deployment is not.
  | Error(Unavailable(why)) => Error(`no secret source: ${why}`)
  | Ok(token) =>
    switch capabilities.secrets.hash(token) {
    | Error(Unavailable(why)) => Error(`cannot hash a secret: ${why}`)
    | Ok(proofHash) =>
      switch await capabilities.messaging.send(
        ~recipient=contact->V.toRecipient,
        ~message={subject: "Confirm your email address", body: body(~token)},
      ) {
      | Ok(_) =>
        Ok(
          Some((
            item.customerId,
            IssueEmailChallenge({
              customerId: item.customerId,
              email: item.email,
              purpose: "ContactChange",
              proofHash,
              issuedAt: Date.make()->Date.toISOString,
            }),
          )),
        )
      // Retryable or not, the answer here is the same: no challenge opens. A
      // failed send is not a verdict on the address — nothing about it is
      // recorded, so the sweep can try again and the address simply stays
      // unproven meanwhile.
      | Error(failure) => Error(Reventless.Messaging.failureReason(failure))
      }
    }
  }
}

/**
The budget is spent and no message ever went.

Nothing is reported. Unlike a geocode, where recording *unresolvable* beats
leaving a row pending forever, there is no verdict to record here: the address
is not disproven by a mail outage, and writing one would mark it as having
failed something it was never asked.
*/
let onExhausted = (_id, _item: outboundItem, ~lastError as _) => None
