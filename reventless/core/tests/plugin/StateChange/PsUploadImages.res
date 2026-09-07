// Test fixture spec for the uploadable semantic types.
//
// The store is not written anywhere: it is the field's name, pluralised. This
// fixture carries the four shapes the derivation has to get right — a required
// field, an optional one, an array (whose marker goes on the element), and an
// explicit `@storageRef` override that keeps the type's semantic while
// replacing the derived store.

@@reventless.spec("UploadImages")

type state = bool
let initialState = false

@schema
type consumedEvent = ProductAdded

let evolve = (_state, _event) => true

@schema
type command =
  | UploadImages({
      productId: string,
      // → `productImages`
      productImage: Reventless.UploadableImage.t,
      // → `categoryImages`, through the optional wrapper
      categoryImage?: Reventless.UploadableImage.t,
      // → `datasheets`; already plural, so the derivation is idempotent
      datasheets: array<Reventless.UploadableFile.t>,
      // The documented override: another plugin's store, and the field keeps
      // `uploadableImage` rather than being downgraded to a bare storage ref.
      @storageRef("branding.logos") logo: Reventless.UploadableImage.t,
    })

@schema
type error = ProductNotFound

@schema
type event = ImagesUploaded({productId: string, productImage: Reventless.UploadableImage.t})

let decide = (_state, _command): result<array<event>, error> => Ok([])
