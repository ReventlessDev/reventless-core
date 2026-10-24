@@reventless.gwt

open Registration_Examples

// The registration ledger. What it must never do is answer an anonymous caller
// differently for a closed policy, a taken address and a fresh one — every arm
// here is an event or nothing, never an error — and what it must never record
// is a secret: only its hash.

let email = alice
let scope = defaultScope
let requestedAt = "2026-10-24T09:00:00.000Z"
let issuedAt = "2026-10-24T09:00:05.000Z"
let soonAfter = "2026-10-24T09:10:00.000Z"
let nextDay = "2026-10-25T09:00:06.000Z"
let nextDayLater = "2026-10-25T09:30:00.000Z"
let twoHoursOn = "2026-10-25T11:00:07.000Z"
let windowEnd = "2026-10-24T08:00:00.000Z"

let opened: array<consumedEvent> = [RegistrationOpened({scopeId: scope})]
let requested: array<consumedEvent> =
  opened->Array.concat([RegistrationRequested({email, requestedAt})])
let challenged: array<consumedEvent> =
  requested->Array.concat([RegistrationChallengeIssued({email, proofHash: secretHash, issuedAt})])
let verified: array<consumedEvent> =
  challenged->Array.concat([RegistrationProofAccepted({email, proofHash: secretHash})])
let completed: array<consumedEvent> =
  verified->Array.concat([RegistrationCompleted({email: email})])

let register = (~at=requestedAt) => Register({email, scopeId: scope, requestedAt: at})
let submit = (~hash=secretHash, ~at=soonAfter) => SubmitRegistrationProof({
  email,
  proofHash: hash,
  presentedAt: at,
})
let wrong: consumedEvent = RegistrationProofRefused({email, reason: "ProofMismatch"})

describe("Registrations StateChangeSlice", () => {
  // 🚨 The policy is read in the same decision as the address, as its own clause,
  // so a policy closed while a registration is being decided fails the append
  // rather than slipping past it.
  // scenario-id: 49225316-1861-49eb-a48c-474b197b557c
  test("a registration is conditioned on the policy as well as the address", () =>
    givenEvents(opened)
    ->whenCmd(register())
    ->thenAppendsConditionedOn([
      {
        // The address's own history. The policy's two types ride along because a
        // single-slice view cannot prove they never carry the address; they match
        // nothing here.
        eventTypes: [
          "RegistrationOpened",
          "RegistrationClosed",
          "RegistrationRequested",
          "RegistrationExpired",
          "RegistrationAttemptedOnTakenAddress",
          "RegistrationChallengeIssued",
          "RegistrationProofAccepted",
          "RegistrationProofRefused",
          "RegistrationCompleted",
        ],
        tags: [{key: "contactAddress", value: email->ContactAddressId.toString}],
      },
      {
        eventTypes: ["RegistrationOpened", "RegistrationClosed"],
        tags: [{key: "scopeId", value: scope}],
      },
    ])
  )

  // 🚨 Closed is the default, and it sends nothing — not even a notice.
  // scenario-id: a093e1a8-62f1-4f28-b7e0-28920fda60bb
  test("a closed policy records nothing", () => givenEvents([])->whenCmd(register())->thenNoEvent)

  // scenario-id: 358a6a64-4227-4c3c-b2e9-72e666c27184
  test("an open policy claims the address", () =>
    givenEvents(opened)
    ->whenCmd(register())
    ->thenEvent(RegistrationRequested({email, requestedAt}))
  )

  // A window someone forgot to close closes itself, with no event to close it.
  // scenario-id: ee7d41c0-5f7d-4ae2-a9e2-5af69a071833
  test("past an open window's end, it refuses exactly as closed does", () =>
    givenEvents([RegistrationOpened({scopeId: scope, until: windowEnd})])
    ->whenCmd(register())
    ->thenNoEvent
  )

  // scenario-id: 8206c898-8733-4858-996c-2e253f63ea3a
  test("within an open window's end, it claims the address", () =>
    givenEvents([RegistrationOpened({scopeId: scope, until: nextDay})])
    ->whenCmd(register())
    ->thenEvent(RegistrationRequested({email, requestedAt}))
  )

  // scenario-id: dd3c4e5d-f19a-48b9-8011-b9cd63849b75
  test("closing the policy stops registrations it had admitted", () =>
    givenEvents(opened->Array.concat([RegistrationClosed({scopeId: scope})]))
    ->whenCmd(register())
    ->thenNoEvent
  )

  // scenario-id: 7c2c6eea-6ae0-4de0-930f-cea318e1e553
  test("a second request while one is pending records nothing", () =>
    givenEvents(challenged)->whenCmd(register(~at=soonAfter))->thenNoEvent
  )

  // 🚨 The security test: the caller is answered as for a fresh address, and the
  // address is told someone tried.
  // scenario-id: 27985e0e-cd57-42f8-9781-760d0ebc2a3a
  test("a registered address records the attempt, not a registration", () =>
    givenEvents(completed)
    ->whenCmd(register(~at=nextDay))
    ->thenEvent(RegistrationAttemptedOnTakenAddress({email, attemptedAt: nextDay}))
  )

  // The notice is the one thing the door makes the deployment send to someone
  // who did not ask; a second attempt within the hour sends nothing more.
  // scenario-id: 8ac35a9c-5d8b-441a-95bc-64768139ef97
  test("a second attempt on a registered address within the hour sends no second notice", () =>
    givenEvents(
      completed->Array.concat([RegistrationAttemptedOnTakenAddress({email, attemptedAt: nextDay})]),
    )
    ->whenCmd(register(~at=nextDayLater))
    ->thenNoEvent
  )

  // scenario-id: b0425f3e-52a6-40e5-89a4-8b70f8de2fb2
  test("after the hour, a registered address is told again", () =>
    givenEvents(
      completed->Array.concat([RegistrationAttemptedOnTakenAddress({email, attemptedAt: nextDay})]),
    )
    ->whenCmd(register(~at=twoHoursOn))
    ->thenEvent(RegistrationAttemptedOnTakenAddress({email, attemptedAt: twoHoursOn}))
  )

  // scenario-id: 5c409dc3-76f6-4311-9943-d655fc11f38e
  test("an abandoned registration releases the address", () =>
    givenEvents(challenged)
    ->whenCmd(register(~at=nextDay))
    ->thenEvents([
      RegistrationExpired({email: email}),
      RegistrationRequested({email, requestedAt: nextDay}),
    ])
  )

  // scenario-id: 77738b1e-b5a2-41ab-888f-7cc6b0d44cdd
  test("a pending registration opens a challenge against a hash", () =>
    givenEvents(requested)
    ->whenCmd(IssueRegistrationChallenge({email, proofHash: secretHash, issuedAt}))
    ->thenEvent(RegistrationChallengeIssued({email, proofHash: secretHash, issuedAt}))
  )

  // scenario-id: 85ae672c-cfa3-4b26-817f-adc83b7437bd
  test("a redelivered challenge request opens nothing", () =>
    givenEvents(challenged)
    ->whenCmd(IssueRegistrationChallenge({email, proofHash: "another", issuedAt: soonAfter}))
    ->thenNoEvent
  )

  // scenario-id: 311f471f-6f65-4d6a-9e8b-690f3918cc0c
  test("the right proof settles the registration", () =>
    givenEvents(challenged)
    ->whenCmd(submit())
    ->thenEvent(RegistrationProofAccepted({email, proofHash: secretHash}))
  )

  // scenario-id: 055e3684-db0f-40f0-9e4a-fdba6cddb70c
  test("a wrong proof is counted, not settled", () =>
    givenEvents(challenged)
    ->whenCmd(submit(~hash="hash-of-a-guess"))
    ->thenEvent(RegistrationProofRefused({email, reason: "ProofMismatch"}))
  )

  // scenario-id: 01c83ed2-4ac7-4561-b3a6-33007e75b4f3
  test("a proof after the challenge lapsed is refused", () =>
    givenEvents(challenged)
    ->whenCmd(submit(~at=nextDay))
    ->thenEvent(RegistrationProofRefused({email, reason: "ChallengeExpired"}))
  )

  // scenario-id: fb9e68aa-2b1f-4e26-914a-6e691214b863
  test("the right proof after the attempts are spent is refused", () =>
    givenEvents(challenged->Array.concat([wrong, wrong, wrong, wrong, wrong]))
    ->whenCmd(submit())
    ->thenEvent(RegistrationProofRefused({email, reason: "AttemptsExhausted"}))
  )

  // scenario-id: b551a64a-847e-4ec1-aac5-6c4db2c4c904
  test("a settled proof settles once", () =>
    givenEvents(completed)
    ->whenCmd(submit())
    ->thenNoEvent
  )

  // Nothing to count it against, and nothing to tell the caller.
  // scenario-id: 1c30ca00-a65b-48be-a93f-0bed5996894c
  test("a proof with no challenge outstanding records nothing", () =>
    givenEvents(opened)->whenCmd(submit())->thenNoEvent
  )

  // scenario-id: 0ace1364-f882-406d-adce-e0be15803354
  test("an account made for a settled proof completes the registration", () =>
    givenEvents(verified)
    ->whenCmd(RecordRegistrationCompleted({email: email}))
    ->thenEvent(RegistrationCompleted({email: email}))
  )

  // scenario-id: 5e8b1e7b-98e0-4e85-b7bb-c7e76a12f3b6
  test("completion without a settled proof records nothing", () =>
    givenEvents(challenged)
    ->whenCmd(RecordRegistrationCompleted({email: email}))
    ->thenNoEvent
  )
})
