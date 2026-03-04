// Ordering DCB event log specification.
// All events for the Ordering plugin live in this shared log, tagged by their entity ID.

open Reventless
@schema
type event =
  | CustomerRegistered({
      customerId: @s.matches(DcbTag.string) string,
      email: string,
      address: string,
    })
  | EmailChanged({customerId: @s.matches(DcbTag.string) string, email: string})
  | AddressChanged({customerId: @s.matches(DcbTag.string) string, address: string})
  | CustomerDeactivated({customerId: @s.matches(DcbTag.string) string})
  | OrderPlaced({
      orderId: @s.matches(DcbTag.string) string,
      customerId: string,
      productIds: array<string>,
    })
  | OrderShipped({orderId: @s.matches(DcbTag.string) string})
  | OrderCancelled({
      orderId: @s.matches(DcbTag.string) string,
      productIds: array<string>,
    })
  | CatalogProductSynced({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      price: float,
    })
  | CatalogProductPriceChanged({
      productId: @s.matches(DcbTag.string) string,
      price: float,
    })
