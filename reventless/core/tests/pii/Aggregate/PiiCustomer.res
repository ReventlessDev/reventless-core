// Fixture: an aggregate's spec, whose events name no subject: the aggregate is it.

@@reventless.spec("PiiCustomer")

@schema
type event =
  | Registered({@pii email: Reventless.Email.t, @pii address: string})
  | EmailUpdated({@pii email: Reventless.Email.t})
  // A field about someone else still names them.
  | ReferralSent({friendId: string, @pii("friendId") friendEmail: Reventless.Email.t})
  | Deactivated

@schema
type command = Register({@pii email: Reventless.Email.t, @pii address: string})
