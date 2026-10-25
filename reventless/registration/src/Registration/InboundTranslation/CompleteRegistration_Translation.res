@@reventless.translation

/** How long a password waits for the ledger to accept the proof it came with. */
let passwordTtl = 600

/** The shortest password accepted here. Checked at the door so a pool's policy
    does not refuse it after the proof has been spent. */
let minimumPasswordLength = 12

let translate = async (
  input: externalInput,
  ~capabilities: Reventless.Capabilities.t,
  ~caller as _: option<Reventless.Identity.t>,
) =>
  switch Reventless.Email.fromString(input.email->String.trim) {
  | Error(_) => Error("not an email address")
  | Ok(_) if input.password->String.length < minimumPasswordLength =>
    Error(`a password needs at least ${minimumPasswordLength->Int.toString} characters`)
  | Ok(email) =>
    let email = email->Reventless.Email.toString->String.toLowerCase
    switch capabilities.secrets.hash(input.proof->String.trim) {
    | Error(Unavailable(why)) => Error(`cannot hash the proof: ${why}`)
    | Ok(proofHash) =>
      switch await capabilities.stash.put(~key=proofHash, ~value=input.password, ~ttl=passwordTtl) {
      | Error(failure) =>
        Error(`cannot hold the password: ${failure->Reventless.Stash.failureReason}`)
      | Ok() =>
        Ok([
          (
            email,
            SubmitRegistrationProof({
              email: ContactAddressId.makeFromString(email),
              proofHash,
              presentedAt: Date.make()->Date.toISOString->Reventless.DateTime.unsafe,
            }),
          ),
        ])
      }
    }
  }
