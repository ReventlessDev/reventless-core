// Customer aggregate specification.
// A registered buyer with contact details and account status.

open ReventlessSpec
module Id = Id.String

let name = "Customer"

@schema
type command =
  | RegisterCustomer({customerId: string, email: string, address: string})
  | UpdateEmail({customerId: string, email: string})
  | UpdateAddress({customerId: string, address: string})
  | DeactivateCustomer({customerId: string})

@schema
type event =
  | CustomerRegistered({customerId: string, email: string, address: string})
  | EmailUpdated({customerId: string, email: string})
  | AddressUpdated({customerId: string, address: string})
  | CustomerDeactivated({customerId: string})

@schema
type error =
  | CustomerAlreadyRegistered
  | CustomerNotFound
  | CustomerAlreadyDeactivated
