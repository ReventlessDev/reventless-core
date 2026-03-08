// Ordering DCB event log specification (hybrid).
// Contains only Order + CatalogProduct events. Customer events live in the Customer
// aggregate's own event log, not here.

open Reventless
@schema
type event =
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
