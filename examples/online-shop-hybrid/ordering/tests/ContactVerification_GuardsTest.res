// The graft's decision rules. The first block is the security test, and it is
// the reason this competency is built on a host that already has an address
// rather than out of the registration flow: registration has nothing to
// supersede, so a trait extracted from it would ship this guard untested.

module Outcome = ReventlessGwt.Outcome
module Bind = ReventlessGwt.JestBind
module V = ContactVerification
module G = ContactVerification_Guards

let email = raw => V.ByEmail(Reventless.Email.fromString(raw)->Result.getOr(raw))

let alice = email("alice@example.com")
let aliceNew = email("alice@new.example.com")
let policy = V.emailPolicy

let at = iso => Reventless.DateTime.fromString(iso)->Result.getOr(iso)
let issued = at("2026-09-10T09:00:00.000Z")
let soonAfter = at("2026-09-10T09:05:00.000Z")
let nextDay = at("2026-09-11T09:00:01.000Z")

// Rendered rather than compared structurally, so a failure names the arm that
// came back instead of printing two records.
let showRefusal = (r: G.refusal) =>
  switch r {
  | AddressSuperseded => "AddressSuperseded"
  | ChallengeExpired => "ChallengeExpired"
  | AlreadySettled => "AlreadySettled"
  | AttemptsExhausted => "AttemptsExhausted"
  | ProofMismatch => "ProofMismatch"
  }

let showProof = (v: G.proofVerdict) =>
  switch v {
  | Settle => "Settle"
  | Refuse(r) => `Refuse(${showRefusal(r)})`
  }

let showIssuance = (i: G.issuance) =>
  switch i {
  | Issue => "Issue"
  | AlreadyOpen => "AlreadyOpen"
  }

let showResend = (r: G.resend) =>
  switch r {
  | Send => "Send"
  | TooSoon(left) => `TooSoon(${left->Int.toString})`
  | NothingOpen => "NothingOpen"
  }

let is = (actual, ~expected) =>
  actual == expected ? Outcome.pass : Outcome.fail(TranslateError({expected, actual: Some(actual)}))

let openChallenge: G.challenge = {
  contact: alice,
  purpose: V.ContactChange,
  issuedAt: issued,
  attempts: 0,
  settled: false,
}

let proof = (hostContact, c, ~proofMatches, ~now) =>
  G.onProofPresented(c, ~hostContact, ~proofMatches, ~now, ~policy)->showProof

Bind.describe("the staleness guard", () => {
  // 🚨 Change the address, then present the old address's proof. Without this
  // guard that sequence is an account takeover, and it is the one property that
  // has to hold under every host shape.
  Bind.test("a proof for a superseded address settles nothing", () =>
    proof(Some(aliceNew), openChallenge, ~proofMatches=true, ~now=soonAfter)->is(
      ~expected="Refuse(AddressSuperseded)",
    )
  )

  // A superseded challenge that had also lapsed must be refused on the fact that
  // makes it dangerous, not on whichever property happened to lapse first.
  Bind.test("supersession outranks expiry", () =>
    proof(Some(aliceNew), openChallenge, ~proofMatches=true, ~now=nextDay)->is(
      ~expected="Refuse(AddressSuperseded)",
    )
  )

  Bind.test("the same address is not superseded", () =>
    proof(Some(alice), openChallenge, ~proofMatches=true, ~now=soonAfter)->is(~expected="Settle")
  )
})

Bind.describe("replay", () => {
  Bind.test("a settled challenge settles once", () =>
    proof(Some(alice), {...openChallenge, settled: true}, ~proofMatches=true, ~now=soonAfter)->is(
      ~expected="Refuse(AlreadySettled)",
    )
  )
})

Bind.describe("lazy expiry", () => {
  // Decided when the proof arrives. No scheduled fire, and no clock control in
  // the test — the instant is an argument.
  Bind.test("a proof after the window yields expired", () =>
    proof(Some(alice), openChallenge, ~proofMatches=true, ~now=nextDay)->is(
      ~expected="Refuse(ChallengeExpired)",
    )
  )

  Bind.test("a proof inside the window does not", () =>
    proof(Some(alice), openChallenge, ~proofMatches=true, ~now=soonAfter)->is(~expected="Settle")
  )
})

Bind.describe("attempts", () => {
  Bind.test("a spent challenge refuses before the proof is looked at", () =>
    proof(
      Some(alice),
      {...openChallenge, attempts: policy.maxAttempts},
      ~proofMatches=false,
      ~now=soonAfter,
    )->is(~expected="Refuse(AttemptsExhausted)")
  )

  Bind.test("a wrong proof with attempts left is a mismatch", () =>
    proof(Some(alice), openChallenge, ~proofMatches=false, ~now=soonAfter)->is(
      ~expected="Refuse(ProofMismatch)",
    )
  )
})

Bind.describe("the stand-down", () => {
  // The same arm as a map picker having already supplied the point: a verdict
  // arrived another way, so spend no capability call.
  Bind.test("an already-verified address owes nothing", () =>
    (G.contactToVerify({contact: alice, verifiedAddress: Some(alice)}) == None)
    ->String.make
    ->is(~expected="true")
  )

  Bind.test("an address verified before it changed owes a proof again", () =>
    (G.contactToVerify({contact: aliceNew, verifiedAddress: Some(alice)}) == Some(aliceNew))
    ->String.make
    ->is(~expected="true")
  )

  // 🚨 A registration has no host at all, so there is nothing for the challenge
  // to be superseded by. `None` means exactly that, and must not read as "skip
  // the check" — the host's own write-back guard is what covers that flow.
  Bind.test("with no host there is nothing to supersede", () =>
    proof(None, openChallenge, ~proofMatches=true, ~now=soonAfter)->is(~expected="Settle")
  )
})

Bind.describe("issuance", () => {
  Bind.test("nothing open means mint and send", () =>
    G.onIssueRequested(~contact=alice, ~existing=None, ~now=soonAfter, ~policy)
    ->showIssuance
    ->is(~expected="Issue")
  )

  // Commands arrive at least once and a slice republishes until its work
  // clears, so a repeated request must not mint a second secret.
  Bind.test("a redelivered request mints nothing", () =>
    G.onIssueRequested(~contact=alice, ~existing=Some(openChallenge), ~now=soonAfter, ~policy)
    ->showIssuance
    ->is(~expected="AlreadyOpen")
  )

  Bind.test("an expired challenge is reopened rather than left standing", () =>
    G.onIssueRequested(~contact=alice, ~existing=Some(openChallenge), ~now=nextDay, ~policy)
    ->showIssuance
    ->is(~expected="Issue")
  )

  Bind.test("a challenge for the previous address does not cover the new one", () =>
    G.onIssueRequested(~contact=aliceNew, ~existing=Some(openChallenge), ~now=soonAfter, ~policy)
    ->showIssuance
    ->is(~expected="Issue")
  )
})

Bind.describe("the resend cooldown", () => {
  Bind.test("too soon says how long is left", () =>
    G.onResendRequested(
      ~contact=alice,
      ~existing=Some(openChallenge),
      ~now=at("2026-09-10T09:00:20.000Z"),
      ~policy,
    )
    ->showResend
    ->is(~expected="TooSoon(40)")
  )

  Bind.test("past the cooldown the same secret goes again", () =>
    G.onResendRequested(~contact=alice, ~existing=Some(openChallenge), ~now=soonAfter, ~policy)
    ->showResend
    ->is(~expected="Send")
  )

  Bind.test("there is nothing to resend once it is settled", () =>
    G.onResendRequested(
      ~contact=alice,
      ~existing=Some({...openChallenge, settled: true}),
      ~now=soonAfter,
      ~policy,
    )
    ->showResend
    ->is(~expected="NothingOpen")
  )
})

Bind.describe("the vocabulary", () => {
  Bind.test("an address lifts totally into a recipient", () =>
    (V.toRecipient(alice) == Reventless.Messaging.ToEmail("alice@example.com"))
    ->String.make
    ->is(~expected="true")
  )

  Bind.test("an email address is reachable over email", () =>
    (V.channelsFor(alice) == [Reventless.Messaging.Email])->String.make->is(~expected="true")
  )

  // Structural, not unfinished: a push token is issued to an app install over a
  // session this flow would be trying to create.
  Bind.test("push carries no policy at all", () =>
    (V.policyFor(Push) == None)->String.make->is(~expected="true")
  )

  Bind.test("email and sms each carry one", () =>
    (V.policyFor(Email)->Option.isSome && V.policyFor(Sms)->Option.isSome)
    ->String.make
    ->is(~expected="true")
  )
})
