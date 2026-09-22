@@reventless.gwt

open OrderingExamples

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
    customerId: c1,
    email: "alice@x.y",
    purpose: "ContactChange",
    proofHash: "hash-of-the-secret",
    issuedAt,
  }),
]

let settled: array<consumedEvent> =
  openChallenge->Array.concat([EmailProofAccepted({customerId: c1, email: "alice@x.y"})])

let wrongOnce: consumedEvent = EmailProofRefused({
  customerId: c1,
  email: "alice@x.y",
  reason: "ProofMismatch",
})

describe("EmailVerificationChallenges StateChangeSlice", () => {
  // scenario-id: 91537909-9b03-4886-85a9-e347a89882c5
  test("a first request mints a challenge", () =>
    givenEvents([])
    ->whenCmd(
      IssueEmailChallenge({
        customerId: c1,
        email: aliceEmail,
        purpose: contactChange,
        proofHash: secretHash,
        issuedAt,
      }),
    )
    ->thenEvent(
      EmailChallengeIssued({
        customerId: c1,
        email: aliceEmail,
        purpose: contactChange,
        proofHash: secretHash,
        issuedAt,
      }),
    )
  )

  // Commands arrive at least once. A second delivery must not mint a second
  // secret — and because the send hangs off the event, emitting nothing is also
  // what stops a second message going out.
  // scenario-id: add58e05-47f6-47ba-8026-bd16014610f8
  test("a redelivered request mints nothing", () =>
    givenEvents(openChallenge)
    ->whenCmd(
      IssueEmailChallenge({
        customerId: c1,
        email: aliceEmail,
        purpose: contactChange,
        proofHash: "a-different-secret",
        issuedAt: soonAfter,
      }),
    )
    ->thenNoEvent
  )

  // scenario-id: c97f6d0e-d82c-47a2-b2ae-7efeb418af40
  test("a matching proof settles the challenge", () =>
    givenEvents(openChallenge)
    ->whenCmd(
      SubmitEmailProof({
        customerId: c1,
        email: aliceEmail,
        proofHash: secretHash,
        presentedAt: soonAfter,
      }),
    )
    ->thenEvent(EmailProofAccepted({customerId: c1, email: aliceEmail}))
  )

  // Recorded rather than returned, so the attempt is counted. A refusal that came
  // back as an error would leave the budget resetting on every replay.
  // scenario-id: af7da30e-c375-40c9-817d-f991ed0a1d5d
  test("a wrong proof is refused as a fact", () =>
    givenEvents(openChallenge)
    ->whenCmd(
      SubmitEmailProof({
        customerId: c1,
        email: aliceEmail,
        proofHash: "wrong",
        presentedAt: soonAfter,
      }),
    )
    ->thenEvent(EmailProofRefused({customerId: c1, email: aliceEmail, reason: "ProofMismatch"}))
  )

  // scenario-id: a497d448-1368-45a4-a618-988e249ea116
  test("a settled challenge settles once", () =>
    givenEvents(settled)
    ->whenCmd(
      SubmitEmailProof({
        customerId: c1,
        email: aliceEmail,
        proofHash: secretHash,
        presentedAt: soonAfter,
      }),
    )
    ->thenEvent(EmailProofRefused({customerId: c1, email: aliceEmail, reason: "AlreadySettled"}))
  )

  // Expiry is decided here, when the proof arrives, against the instant the
  // command carries — no scheduled fire, and no clock to control.
  // scenario-id: 84997537-424d-4787-ba4a-26bd54d700b9
  test("a proof after the window is refused as expired", () =>
    givenEvents(openChallenge)
    ->whenCmd(
      SubmitEmailProof({
        customerId: c1,
        email: aliceEmail,
        proofHash: secretHash,
        presentedAt: nextDay,
      }),
    )
    ->thenEvent(EmailProofRefused({customerId: c1, email: aliceEmail, reason: "ChallengeExpired"}))
  )

  // Five wrong answers spend the budget; the sixth is refused on the budget
  // rather than on the secret, so a spent challenge stops being an oracle.
  // scenario-id: 64e927aa-6429-4ca9-ad1e-d7f542dc0dea
  test("the attempt budget is spent by recorded refusals", () =>
    givenEvents(
      openChallenge->Array.concat([wrongOnce, wrongOnce, wrongOnce, wrongOnce, wrongOnce]),
    )
    ->whenCmd(
      SubmitEmailProof({
        customerId: c1,
        email: aliceEmail,
        proofHash: secretHash,
        presentedAt: soonAfter,
      }),
    )
    ->thenEvent(EmailProofRefused({customerId: c1, email: aliceEmail, reason: "AttemptsExhausted"}))
  )

  // Nothing to count an attempt against, so this is the one refusal that is an
  // error rather than a fact.
  // scenario-id: 6498c1c7-b9d5-4bcc-bbbc-7a599d619c41
  test("a proof with no challenge outstanding is refused", () =>
    givenEvents([])
    ->whenCmd(
      SubmitEmailProof({
        customerId: c1,
        email: aliceEmail,
        proofHash: secretHash,
        presentedAt: soonAfter,
      }),
    )
    ->thenError(NoChallengeOutstanding)
  )
})
