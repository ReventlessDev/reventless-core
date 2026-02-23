// CatalogItem aggregate specification.
// Demonstrates the Reventless aggregate spec pattern using the CatalogItem domain.

module Id = ReventlessSpec.Id.String

let name = "CatalogItem"

@schema
type command =
  | CreateItem({itemId: string, name: string, description: string})
  | UpdateItem({itemId: string, name: string, description: string})
  | ArchiveItem({itemId: string})

@schema
type event =
  | ItemCreated({itemId: string, name: string, description: string})
  | ItemUpdated({itemId: string, name: string, description: string})
  | ItemArchived({itemId: string})

@schema
type error =
  | ItemAlreadyExists
  | ItemNotFound
  | ItemAlreadyArchived
