// Customer aggregate specification.
// A registered buyer with contact details and account status.

open Reventless
module Id = Id.String

let name = "Customer"

@schema
type command =
  | Register({email: string, address: string})
  | UpdateEmail({email: string})
  | UpdateAddress({address: string})
  | Deactivate

@schema
type event =
  | Registered({email: string, address: string})
  | EmailUpdated({email: string})
  | AddressUpdated({address: string})
  | Deactivated

@schema
type error =
  | CustomerAlreadyRegistered
  | CustomerNotFound
  | CustomerAlreadyDeactivated

let moduleUrl: string = %raw(`import.meta.url`)
