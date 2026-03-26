// Catalog DCB event log type definition (hybrid).
// Contains only Product + ProductDemand events. Category events live in the Category aggregate's
// own event log, not here.

open Reventless
@schema
type event =
  | ProductAdded({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })
  | ProductNameChanged({productId: @s.matches(DcbTag.string) string, name: string})
  | ProductDescriptionChanged({
      productId: @s.matches(DcbTag.string) string,
      description: string,
    })
  | ProductPriceChanged({productId: @s.matches(DcbTag.string) string, price: float})
  | ProductDemandRecorded({
      productId: @s.matches(DcbTag.string) string,
      orderId: string,
    })
  | ProductDemandRevoked({
      productId: @s.matches(DcbTag.string) string,
      orderId: string,
    })
