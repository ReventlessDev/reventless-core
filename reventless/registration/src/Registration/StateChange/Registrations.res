// Registrations StateChangeSlice.
//
// One registration per address: the address claimed, the challenge sent to it,
// the proof that answers the challenge, and the account that follows. The claim
// is a DCB tag on the address — `contactAddress` — so "this address is taken" is
// decided here, identically on every platform, rather than by whichever identity
// provider happens to be behind the deployment.
//
// **Verify, then create.** Nothing here creates an account. A registration is
// recorded against the address, the proof settles it, and only then does a
// translation reach the identity provider. An address nobody proved holds no
// account, so there is no unconfirmed account to clean up.
//
// **Every command is relayed, never a client's.** The doors are the inbound
// translations in this chapter: they stamp the time a request arrived, and they
// hash a presented proof so its plaintext never reaches this slice or the log.
//
// **The address is not the key.** `emailId` is the address's keyed fingerprint
// (`ContactAddressId`), which is what tags and partitions the ledger; an index key
// cannot be erased. The address itself rides in `email`, on the events that must
// reach the person and on the commands that start a claim, so it lives only where
// a payload field can be encrypted or erased.
//
// **Its answers do not tell an anonymous caller anything.** A closed policy, a
// pending registration and an address already registered all leave the door
// answering the same way; only what is sent to the address differs.

@@reventless.spec

// The policy's two events are read by role, a reference to another entity: the
// role is an identity the framework declares, so the inference reads it across
// partitions as it reads any id another slice is partitioned by.
@schema
type consumedEvent =
  | RegistrationOpened({
      role: @s.matches(Reventless.DcbTag.mark(Reventless.Role.nameSchema)) Reventless.Role.name,
      until?: Reventless.DateTime.t,
    })
  | RegistrationClosed({
      role: @s.matches(Reventless.DcbTag.mark(Reventless.Role.nameSchema)) Reventless.Role.name,
    })
  | RegistrationRequested({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      roles: array<string>,
      requestedAt: Reventless.DateTime.t,
      language?: string,
    })
  | RegistrationExpired({emailId: ContactAddressId.t})
  | RegistrationInvited({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      roles: array<string>,
      invitedBy: string,
      invitedAt: Reventless.DateTime.t,
      language?: string,
    })
  | RegistrationChallengeReissued({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      reissuedAt: Reventless.DateTime.t,
      invitedBy?: string,
      language?: string,
    })
  | RegistrationWithdrawn({emailId: ContactAddressId.t, withdrawnAt: Reventless.DateTime.t})
  | RegistrationAttemptedOnTakenAddress({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      attemptedAt: Reventless.DateTime.t,
    })
  | RegistrationChallengeIssued({
      emailId: ContactAddressId.t,
      proofHash: string,
      issuedAt: Reventless.DateTime.t,
      /** The language the code went out in, and the key of the mail that carried it: what is
          recorded of a sent mail, never its text. */
      language?: string,
      messageKey?: string,
    })
  | RegistrationProofAccepted({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      roles: array<string>,
      proofHash: string,
    })
  | RegistrationProofRefused({emailId: ContactAddressId.t, reason: string})
  | RegistrationCompleted({emailId: ContactAddressId.t})
  | RegistrationReleased({emailId: ContactAddressId.t, releasedAt: Reventless.DateTime.t})

// `Register` names the role asked for, and the policy is read by it. The
// registration records the roles it grants as
// data, never as a tag: keeping the tag off this slice's own events is what
// makes the role a read of another entity rather than one of this slice's keys,
// so a policy changing while a registration is decided is caught by the append
// condition. A set rather than one role, so a door granting several at once
// records them all; a sign-up records a set of one. Plain names on the events,
// since what they carry is what a settled proof grants, not a key the ledger is
// read by.
@schema
type command =
  | @noApi
  Register({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      role: @s.matches(Reventless.DcbTag.mark(Reventless.Role.nameSchema)) Reventless.Role.name,
      requestedAt: Reventless.DateTime.t,
      language?: string,
    })
  | @noApi
  IssueRegistrationChallenge({
      emailId: ContactAddressId.t,
      proofHash: string,
      issuedAt: Reventless.DateTime.t,
      language?: string,
      messageKey?: string,
    })
  | @noApi
  SubmitRegistrationProof({
      emailId: ContactAddressId.t,
      proofHash: string,
      presentedAt: Reventless.DateTime.t,
    })
  | @noApi RecordRegistrationCompleted({emailId: ContactAddressId.t})
  // A signed-in inviter claims the address for someone else, as the roles the
  // app declares by invitation. No door here reaches it: a plugin that provides
  // invitations marks its door `Invite` and checks the inviter before relaying.
  | @noApi
  Invite({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      roles: array<Reventless.Role.name>,
      invitedBy: string,
      requestedAt: Reventless.DateTime.t,
      language?: string,
    })
  // Voids the code a pending registration holds, so a new one is sent: a code
  // lost, or its attempts spent. Held to one per resend cooldown.
  | @noApi
  ReissueRegistrationChallenge({
      emailId: ContactAddressId.t,
      requestedAt: Reventless.DateTime.t,
    })
  // Releases an address a registration holds and nobody has proved yet.
  | @noApi WithdrawRegistration({emailId: ContactAddressId.t, withdrawnAt: Reventless.DateTime.t})
  // Releases the address of an account that was erased, so its person may
  // register again. Only the erasure workflow sends it, after the account is gone.
  | @noApi ReleaseRegistration({emailId: ContactAddressId.t, releasedAt: Reventless.DateTime.t})

// Every outcome of a command relayed for an anonymous caller is a recorded fact
// or a quiet no-op, never an error: an error is the one answer a caller could
// tell apart. `Invite` is the exception, because its caller is a signed-in
// inviter, who is owed the reason an invitation was not recorded.
@schema
type error =
  | NotByInvitation({role: string})
  | NoRoleToGrant

@schema
type event =
  | RegistrationRequested({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      roles: array<string>,
      requestedAt: Reventless.DateTime.t,
      language?: string,
    })
  | RegistrationExpired({emailId: ContactAddressId.t})
  | RegistrationInvited({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      roles: array<string>,
      invitedBy: string,
      invitedAt: Reventless.DateTime.t,
      language?: string,
    })
  | RegistrationChallengeReissued({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      reissuedAt: Reventless.DateTime.t,
      invitedBy?: string,
      language?: string,
    })
  | RegistrationWithdrawn({emailId: ContactAddressId.t, withdrawnAt: Reventless.DateTime.t})
  | RegistrationAttemptedOnTakenAddress({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      attemptedAt: Reventless.DateTime.t,
    })
  | RegistrationChallengeIssued({
      emailId: ContactAddressId.t,
      proofHash: string,
      issuedAt: Reventless.DateTime.t,
      /** The language the code went out in, and the key of the mail that carried it: what is
          recorded of a sent mail, never its text. */
      language?: string,
      messageKey?: string,
    })
  | RegistrationProofAccepted({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      roles: array<string>,
      proofHash: string,
    })
  | RegistrationProofRefused({emailId: ContactAddressId.t, reason: string})
  | RegistrationCompleted({emailId: ContactAddressId.t})
  | RegistrationReleased({emailId: ContactAddressId.t, releasedAt: Reventless.DateTime.t})
