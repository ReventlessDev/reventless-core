@@reventless.translation

/** The groups that stand for the roles a registration grants, as this
    deployment maps them. */
let groupsOf = (roles: array<Reventless.Role.name>) => roles->Array.map(Reventless.Role.groupOf)

/** How long a password put back for a retry waits again. */
let retryTtl = 600

let collect = (event, ~sourceId as _) =>
  switch event {
  | RegistrationProofAccepted({email, address: Value(address), roles, proofHash}) => [
      (`${email}:${proofHash}`, {email, address, roles, proofHash}),
    ]
  // An address that was erased or forgotten has nobody left to write to.
  | _ => []
  }

// `email` is already the ledger's id for the address: no key is needed to say so.
let completed = (email: string) => Ok(
  Some((email, RecordRegistrationCompleted({email: ContactAddressId.makeFromString(email)}))),
)

let translate = async (_id, item: outboundItem, ~capabilities: Reventless.Capabilities.t) =>
  switch await capabilities.stash.take(~key=item.proofHash) {
  | Error(failure) => Error(failure->Reventless.Stash.failureReason)
  // Gone: the person took longer than the stash holds a password, or a restart
  // emptied it. Retrying cannot bring it back; they register again.
  | Ok(None) => Error("the password expired before the account was made")
  | Ok(Some(password)) =>
    switch await capabilities.identityProvider.createPrincipal(
      ~contact=ToEmail(item.address),
      ~credential=Password(password),
      ~groups=groupsOf(item.roles),
    ) {
    | Ok(_) => completed(item.email)
    // The provider already holds this address — an account declared before
    // registration existed, say. It is as registered as one made here.
    | Error(Conflict) => completed(item.email)
    | Error(Unavailable(why)) =>
      // Put back so the retry finds it. Failing that, the retry reports the
      // password gone, which is true.
      let _ = await capabilities.stash.put(~key=item.proofHash, ~value=password, ~ttl=retryTtl)
      Error(why)
    | Error(Refused(why)) => Error(why)
    }
  }

let onExhausted = (_id, _item: outboundItem, ~lastError as _) => None
