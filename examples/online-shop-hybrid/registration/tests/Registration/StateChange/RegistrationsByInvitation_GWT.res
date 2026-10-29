@@reventless.gwt

open Registration_Examples

// The ledger over an app that admits staff by invitation, which the shop does
// not: the same slice, a different table. An invitation claims the address as
// a sign-up does, holds for a week rather than a day, and settles through the
// same proof into every role it names.

module Ledger = Registrations
module InvitingLedger = Registrations_Decision.Make({
  let table = Reventless.Admission.declare([
    (Roles.Shopper, SelfService),
    (Merchandiser, Invitation({by: [Roles.Admin]})),
    (Fulfilment, Invitation({by: [Roles.Admin]})),
    (Admin, Provisioned),
  ])
})

let email = alice
let address = aliceMail
let fulfilment = Reventless.Role.make("Fulfilment")
let staff = [merchandiser, fulfilment]
let staffNames = [merchandiserName, "Fulfilment"]
let invitedBy = "u_admin"
let invitedAt = "2026-10-24T09:00:00.000Z"
let issuedAt = "2026-10-24T09:00:05.000Z"
let threeDaysOn = "2026-10-27T09:00:00.000Z"
let eightDaysOn = "2026-11-01T09:00:00.000Z"

let invite = (~roles=staff, ~at=invitedAt) => Invite({email, address, roles, invitedBy, requestedAt: at})
let invited: array<consumedEvent> = [
  RegistrationInvited({email, address, roles: staffNames, invitedBy, invitedAt}),
]
let challenged: array<consumedEvent> =
  invited->Array.concat([RegistrationChallengeIssued({email, proofHash: secretHash, issuedAt})])
let submit = (~at) => SubmitRegistrationProof({email, proofHash: secretHash, presentedAt: at})

describe("Registrations StateChangeSlice, by invitation", () => {
  // scenario-id: b076201a-bbe1-436f-9c4e-fbc637e1f0ce
  test("an invitation claims the address as every role it names", () =>
    givenEvents([])
    ->whenCmd(invite())
    ->thenEvent(RegistrationInvited({email, address, roles: staffNames, invitedBy, invitedAt}))
  )

  // The table is the hard cap: a self-service role is signed up for, not invited to.
  // scenario-id: 5d82241b-05c9-4a9a-9f03-a463e53eae61
  test("an invitation naming a role not by invitation is refused, naming it", () =>
    givenEvents([])
    ->whenCmd(invite(~roles=[merchandiser, shopper]))
    ->thenError(NotByInvitation({role: shopperName}))
  )

  // scenario-id: 7f944f2b-8b8a-4e14-9f01-97b702860719
  test("an invitation granting nothing is refused", () =>
    givenEvents([])->whenCmd(invite(~roles=[]))->thenError(NoRoleToGrant)
  )

  // The completion door is the one a sign-up ends at, unchanged.
  // scenario-id: e1b9ec91-240c-43c7-a6e6-20719d977adc
  test("the proof settles an invitation into every role it names", () =>
    givenEvents(challenged)
    ->whenCmd(submit(~at=threeDaysOn))
    ->thenEvent(RegistrationProofAccepted({email, address, roles: staffNames, proofHash: secretHash}))
  )

  // A sign-up's code would have lapsed after a day.
  // scenario-id: 72245b53-6ec2-49a3-9666-f7e74c2643b9
  test("an invitation's code holds past a week only", () =>
    givenEvents(challenged)
    ->whenCmd(submit(~at=eightDaysOn))
    ->thenEvent(RegistrationProofRefused({email, reason: "ChallengeExpired"}))
  )

  // 🚨 A visitor cannot take over an address someone was invited at.
  // scenario-id: 63dcf831-9b27-4ca7-9561-01825ec7cebc
  test("a sign-up for an invited address records nothing while the invitation holds", () =>
    givenEvents(challenged)
    ->whenCmd(Register({email, address, role: shopper, requestedAt: threeDaysOn}))
    ->thenNoEvent
  )

  // scenario-id: 3bfd123b-3031-497d-bdf3-cd360858d7ea
  test("an address that holds an account is not invited", () =>
    givenEvents(
      challenged->Array.concat([
        RegistrationProofAccepted({email, address, roles: staffNames, proofHash: secretHash}),
        RegistrationCompleted({email: email}),
      ]),
    )
    ->whenCmd(invite(~at=threeDaysOn))
    ->thenNoEvent
  )

  // scenario-id: f17c5083-9bf0-45d1-b5ad-2a149609adf5
  test("a lapsed invitation is replaced by a new one", () =>
    givenEvents(challenged)
    ->whenCmd(invite(~at=eightDaysOn))
    ->thenEvents([
      RegistrationExpired({email: email}),
      RegistrationInvited({email, address, roles: staffNames, invitedBy, invitedAt: eightDaysOn}),
    ])
  )

  // So the sender words the new code as an invitation too.
  // scenario-id: d5ea232a-05e3-49b0-ae8f-c4bcdcf8dc9d
  test("a reissued invitation's code says who invited", () =>
    givenEvents(challenged)
    ->whenCmd(ReissueRegistrationChallenge({email, requestedAt: threeDaysOn}))
    ->thenEvent(RegistrationChallengeReissued({email, address, reissuedAt: threeDaysOn, invitedBy}))
  )
})
