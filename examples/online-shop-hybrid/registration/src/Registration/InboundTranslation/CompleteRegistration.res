// CompleteRegistration InboundTranslationSlice.
//
// The anonymous door a registration ends at: the proof that arrived at the
// address, and the password the person chose. The password must reach the
// identity provider and must never reach the log, and whether it may reach the
// provider at all is decided by the ledger, which this door cannot read. So the
// door hashes the proof, puts the password in the stash under that hash, and
// relays only the hash. If the ledger accepts the proof, the slice that reacts
// takes the password and makes the account; if not, the password expires.
//
// Both secrets are `@sensitive`, which keeps them out of this slice's audit rows.

@@reventless.spec
@@reventless.authorize(AllowAnonymous)

@schema
type externalInput = {
  email: string,
  @sensitive proof: string,
  @sensitive password: string,
}

@schema
type command =
  | SubmitRegistrationProof({
      email: ContactAddressId.t,
      proofHash: string,
      presentedAt: Reventless.DateTime.t,
    })

let targetName = "Registrations"
let capabilityNeeds = [Reventless.CapabilityNeed.Stash]

/** This door completes a registration; the platform tells the shell so. */
let admissionDoor = Reventless.Admission.Complete
