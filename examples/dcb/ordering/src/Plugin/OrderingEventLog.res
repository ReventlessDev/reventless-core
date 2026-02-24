// Ordering DCB event log specification.
// All events for the Ordering plugin live in this shared log, tagged by their entity ID.

open ReventlessSpec
@schema
type event =
  | CustomerRegistered({
      customerId: @s.matches(DcbTag.string) string,
      email: string,
      address: string,
    })
  | EmailUpdated({customerId: @s.matches(DcbTag.string) string, email: string})
  | AddressUpdated({customerId: @s.matches(DcbTag.string) string, address: string})
  | CustomerDeactivated({customerId: @s.matches(DcbTag.string) string})
  | OrderPlaced({
      orderId: @s.matches(DcbTag.string) string,
      customerId: string,
      productIds: array<string>,
    })
  | OrderShipped({orderId: @s.matches(DcbTag.string) string})
  | OrderCancelled({orderId: @s.matches(DcbTag.string) string})
