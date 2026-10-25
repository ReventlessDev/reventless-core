@@reventless.examples

let alice: ContactAddressId.t = ContactAddressId.makeFromString("alice@example.com")
let aliceAddress: string = "alice@example.com"
/** The role visitors may sign up for, as `Admission.res` declares it. */
let shopper: Reventless.Role.name = Reventless.Role.make("Shopper")
let shopperName: string = "Shopper"
/** A role made by hand, which no visitor may sign up for. */
let merchandiser: Reventless.Role.name = Reventless.Role.make("Merchandiser")
let merchandiserName: string = "Merchandiser"
let goodPassword: string = "correct horse battery"
let secretHash: string = "hash-of-the-secret"
