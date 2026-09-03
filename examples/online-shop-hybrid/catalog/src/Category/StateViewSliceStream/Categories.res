// Categories StateViewSliceStream.
// Projects category events from the shared catalog event log into a Categories read model.

@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryImageAttached({categoryId: string, categoryImage: Reventless.UploadableImage.t, altText?: string})
  | CategoryImageRemoved({categoryId: string, categoryImage: Reventless.UploadableImage.t})
  | CategoryImageAltTextSet({categoryId: string, categoryImage: Reventless.UploadableImage.t, altText: string})
  | CategoryArchived({categoryId: string})
  | CategoryUnarchived({categoryId: string})

// Where a category is in its life in the catalog. A state rather than a flag
// beside one, so a command's declared edge can name it: that is the whole of "offer
// Unarchive on an archived category and Archive on a listed one".
//
// `@retired` sits on the state it names. Archiving withdraws a category from the
// catalog without deleting it — the products filed under it still name it, and a
// merchandiser still needs to find it — and marking the constructor is what makes
// the platform enforce that: ordinary reads exclude these rows.
@schema
type shelfStatus =
  | Listed
  | @retired Archived

// An archived category keeps its name, for the reason the retirement above
// already gives: the products filed under it still name it, and a live product
// showing `cat-08` where it means "Clearance" is a pointer the platform handed
// out and stopped honouring. The list stays closed — a reference gets id, name
// and state, nothing more.
@schema
@namedWhenRetired
type state = {
  categoryId: string,
  name: string,
  // `@lifecycle` is what makes this the field a command's declared edge is
  // written in terms of, so the way back is offered exactly where it applies.
  // The retirement is on `shelfStatus`'s own constructor and needs no second
  // annotation here.
  @lifecycle shelfStatus: shelfStatus,
  // The image, as one string, for the card and the gallery tile. No collection
  // beside it: a category holds one picture, so the field every surface already
  // reads IS the whole of what it has, and a set of one is a table with one row
  // on a detail page and a cardinality nothing enforces.
  categoryImage?: Reventless.UploadableImage.t,
  // Its caption, so the one image a reader actually sees has alternative text.
  categoryImageAltText?: string,
}
