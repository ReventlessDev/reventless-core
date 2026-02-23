// ItemCatalog DCB event log specification.
// Defines all events in the Item Catalog domain, tagged by itemId for DCB filtering.

@schema
type event =
  | ItemCreated({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})
  | ItemRenamed({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})
  | ItemArchived({itemId: @s.matches(Reventless.DcbTag.string) string})
