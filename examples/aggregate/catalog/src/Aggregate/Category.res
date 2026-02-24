// Category aggregate specification.
// A named grouping of products (e.g. "Books", "Electronics").

open ReventlessSpec
module Id = Id.String

let name = "Category"

@schema
type command =
  | AddCategory({categoryId: string, name: string})
  | RenameCategory({categoryId: string, name: string})
  | ArchiveCategory({categoryId: string})

@schema
type event =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryArchived({categoryId: string})

@schema
type error =
  | CategoryAlreadyExists
  | CategoryNotFound
  | CategoryAlreadyArchived
