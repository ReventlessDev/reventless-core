@@reventless.examples

/** The ledger's id for Alice's address: its fingerprint, as the test secrets
    compute one (`Secrets.fixedFingerprint`). The address itself is never the id. */
let alice: ContactAddressId.t = ContactAddressId.makeFromString(
  "fp:contactAddress:alice@example.com",
)
let aliceId: string = "fp:contactAddress:alice@example.com"
/** Alice's address, as she types it and as mail is sent to it. */
let aliceAddress: string = "alice@example.com"
let aliceMail: Reventless.Email.t = Reventless.Email.unsafe("alice@example.com")
/** The role visitors may sign up for, as `Admission.res` declares it. */
let shopper: Reventless.Role.name = Reventless.Role.make("Shopper")
let shopperName: string = "Shopper"
/** A role made by hand, which no visitor may sign up for. */
let merchandiser: Reventless.Role.name = Reventless.Role.make("Merchandiser")
let merchandiserName: string = "Merchandiser"
let goodPassword: string = "correct horse battery"
let secretHash: string = "hash-of-the-secret"
