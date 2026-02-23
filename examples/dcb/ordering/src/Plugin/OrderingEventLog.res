// Ordering DCB event log specification.
// All events for the Ordering plugin live in this shared log, tagged by their entity ID.

@schema
type event =
  | CustomerRegistered({
      customerId: @s.matches(Reventless.DcbTag.string) string,
      email: string,
      address: string,
    })
  | EmailUpdated({customerId: @s.matches(Reventless.DcbTag.string) string, email: string})
  | AddressUpdated({customerId: @s.matches(Reventless.DcbTag.string) string, address: string})
  | CustomerDeactivated({customerId: @s.matches(Reventless.DcbTag.string) string})
  | OrderPlaced({
      orderId: @s.matches(Reventless.DcbTag.string) string,
      customerId: string,
      productIds: array<string>,
    })
  | OrderShipped({orderId: @s.matches(Reventless.DcbTag.string) string})
  | OrderCancelled({orderId: @s.matches(Reventless.DcbTag.string) string})
