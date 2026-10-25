// How long a registration's code holds, by why it was sent. A sign-up is acted
// on by the person who just asked, so a day is plenty; an invitation waits in the
// mailbox of someone who did not ask, so it holds a week. The rest of the policy
// is the email one. Kept beside the copied challenge rules rather than in them,
// so the copy stays a copy.

/** A week to act on an invitation. */
let invitationTtl: Reventless.Duration.t = 604800

let policyFor = (purpose: ContactVerification.purpose): ContactVerification.policy =>
  switch purpose {
  | Invitation => {...ContactVerification.emailPolicy, tokenTtl: invitationTtl}
  | Registration | ContactChange | Recovery | Custom(_) => ContactVerification.emailPolicy
  }

/** A registration someone was invited to, or one the person asked for. */
let purposeFor = (~invited: bool): ContactVerification.purpose =>
  invited ? Invitation : Registration

let purposeOf = (~invitedBy: option<string>) => purposeFor(~invited=invitedBy->Option.isSome)
