// Categories StateViewSliceStream.
// Projects category events from the shared catalog event log into a Categories read model.

@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryImageAttached({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
      altText?: string,
    })
  | CategoryImageRemoved({categoryId: string, categoryImage: Reventless.UploadableImage.t})
  | CategoryImageAltTextSet({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
      altText: string,
    })
  | CategoryArchived({categoryId: string})
  | CategoryUnarchived({categoryId: string})

// A state rather than a flag, so a command's declared edge can name it.
// `@retired` on the constructor is what withdraws the row from ordinary reads
// without deleting it — the products filed under it still name it.
@schema
type shelfStatus =
  | Listed
  | @retired Archived

// An archived category keeps its name: the products filed under it still name
// it. The list stays closed — a reference gets id, name and state, nothing more.
@schema @namedWhenRetired
type state = {
  categoryId: string,
  name: string,
  // `@lifecycle` makes this the field a command's declared edge is written in
  // terms of; the retirement is on the constructor and needs no annotation here.
  @lifecycle shelfStatus: shelfStatus,
  // When this category reached each shelf state, appended by the projection
  // machinery. Archiving finally has a date; it never had one.
  trail: Reventless.Lifecycle.Trail.t<shelfStatus>,
  // One picture, so a scalar rather than the set Products carries. Named for its
  // store, so `categoryImages` is what is provisioned.
  categoryImage?: Reventless.CaptionedImage.t,
}
