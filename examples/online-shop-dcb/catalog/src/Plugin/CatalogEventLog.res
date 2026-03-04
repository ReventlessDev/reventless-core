// Catalog DCB event log specification.
// All events for the Catalog plugin live in this shared log, tagged by their entity ID.

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
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryRenamed({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})
  | ProductDemandRecorded({
      productId: @s.matches(DcbTag.string) string,
      orderId: string,
    })
  | ProductDemandRevoked({
      productId: @s.matches(DcbTag.string) string,
      orderId: string,
    })
