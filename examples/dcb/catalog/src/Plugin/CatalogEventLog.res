// Catalog DCB event log specification.
// All events for the Catalog plugin live in this shared log, tagged by their entity ID.

@schema
type event =
  | ProductAdded({
      productId: @s.matches(Reventless.DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })
  | ProductNameUpdated({productId: @s.matches(Reventless.DcbTag.string) string, name: string})
  | ProductDescriptionUpdated({
      productId: @s.matches(Reventless.DcbTag.string) string,
      description: string,
    })
  | ProductPriceUpdated({productId: @s.matches(Reventless.DcbTag.string) string, price: float})
  | CategoryAdded({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})
  | CategoryRenamed({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})
  | CategoryArchived({categoryId: @s.matches(Reventless.DcbTag.string) string})
