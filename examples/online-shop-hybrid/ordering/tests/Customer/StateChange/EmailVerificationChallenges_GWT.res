@@reventless.gwt

// The challenge ledger. What it owns is one secret at a time: issue it, count
// wrong answers against it, settle it once, and let it lapse on its own.
//
// The secret is never in a command or an event — only its hash — so these
// scenarios compare hashes too. `decide` stays pure that way, which is what lets
// the attempt count survive a replay.

let issuedAt = "2026-09-10T09:00:00.000Z"
let soonAfter = "2026-09-10T09:05:00.000Z"
let nextDay = "2026-09-11T09:00:01.000Z"

// Annotated as consumed: `givenEvents` replays this slice's past, and the
// produced and consumed types carry the same constructors.
let openChallenge: array<consumedEvent> = [
  EmailChallengeIssued({
    customerId: "c1",
    email: "alice@x.y",
    purpose: "ContactChange",
    proofHash: "hash-of-the-secret",
    issuedAt,
  }),
]

let settled: array<consumedEvent> =
  openChallenge->Array.concat([EmailProofAccepted({customerId: "c1", email: "alice@x.y"})])

let wrongOnce: consumedEvent = EmailProofRefused({
  customerId: "c1",
  email: "alice@x.y",
  reason: "ProofMismatch",
})

describe("EmailVerificationChallenges StateChangeSlice", () => {
  test("a first request mints a challenge", () =>
    givenEvents([])
    ->whenCmd(
      IssueEmailChallenge({
        customerId: "c1",
        email: "alice@x.y",
        purpose: "ContactChange",
        proofHash: "hash-of-the-secret",
        issuedAt,
      }),
    )
    ->thenEvent(
      EmailChallengeIssued({
        customerId: "c1",
        email: "alice@x.y",
        purpose: "ContactChange",
        proofHash: "hash-of-the-secret",
        issuedAt,
      }),
    )
  )

  // Commands arrive at least once. A second delivery must not mint a second
  // secret — and because the send hangs off the event, emitting nothing is also
  // what stops a second message going out.
  test("a redelivered request mints nothing", () =>
    givenEvents(openChallenge)
    ->whenCmd(
      IssueEmailChallenge({
        customerId: "c1",
        email: "alice@x.y",
        purpose: "ContactChange",
        proofHash: "a-different-secret",
        issuedAt: soonAfter,
      }),
    )
    ->thenNoEvent
  )

  test("a matching proof settles the challenge", () =>
    givenEvents(openChallenge)
    ->whenCmd(
      SubmitEmailProof({
        customerId: "c1",
        email: "alice@x.y",
        proofHash: "hash-of-the-secret",
        presentedAt: soonAfter,
      }),
    )
    ->thenEvent(EmailProofAccepted({customerId: "c1", email: "alice@x.y"}))
  )

  // Recorded rather than returned, so the attempt is counted. A refusal that came
  // back as an error would leave the budget resetting on every replay.
  test("a wrong proof is refused as a fact", () =>
    givenEvents(openChallenge)
    ->whenCmd(
      SubmitEmailProof({
        customerId: "c1",
        email: "alice@x.y",
        proofHash: "wrong",
        presentedAt: soonAfter,
      }),
    )
    ->thenEvent(EmailProofRefused({customerId: "c1", email: "alice@x.y", reason: "ProofMismatch"}))
  )

  test("a settled challenge settles once", () =>
    givenEvents(settled)
    ->whenCmd(
      SubmitEmailProof({
        customerId: "c1",
        email: "alice@x.y",
        proofHash: "hash-of-the-secret",
        presentedAt: soonAfter,
      }),
    )
    ->thenEvent(EmailProofRefused({customerId: "c1", email: "alice@x.y", reason: "AlreadySettled"}))
  )

  // Expiry is decided here, when the proof arrives, against the instant the
  // command carries — no scheduled fire, and no clock to control.
  test("a proof after the window is refused as expired", () =>
    givenEvents(openChallenge)
    ->whenCmd(
      SubmitEmailProof({
        customerId: "c1",
        email: "alice@x.y",
        proofHash: "hash-of-the-secret",
        presentedAt: nextDay,
      }),
    )
    ->thenEvent(
      EmailProofRefused({customerId: "c1", email: "alice@x.y", reason: "ChallengeExpired"}),
    )
  )

  // Five wrong answers spend the budget; the sixth is refused on the budget
  // rather than on the secret, so a spent challenge stops being an oracle.
  test("the attempt budget is spent by recorded refusals", () =>
    givenEvents(
      openChallenge->Array.concat([wrongOnce, wrongOnce, wrongOnce, wrongOnce, wrongOnce]),
    )
    ->whenCmd(
      SubmitEmailProof({
        customerId: "c1",
        email: "alice@x.y",
        proofHash: "hash-of-the-secret",
        presentedAt: soonAfter,
      }),
    )
    ->thenEvent(
      EmailProofRefused({customerId: "c1", email: "alice@x.y", reason: "AttemptsExhausted"}),
    )
  )

  // Nothing to count an attempt against, so this is the one refusal that is an
  // error rather than a fact.
  test("a proof with no challenge outstanding is refused", () =>
    givenEvents([])
    ->whenCmd(
      SubmitEmailProof({
        customerId: "c1",
        email: "alice@x.y",
        proofHash: "hash-of-the-secret",
        presentedAt: soonAfter,
      }),
    )
    ->thenError(NoChallengeOutstanding)
  )
})
