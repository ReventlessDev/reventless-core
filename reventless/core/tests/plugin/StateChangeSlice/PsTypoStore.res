// Test fixture spec for the near-duplicate-store check.
//
// Two uploadable fields whose names differ by a transposition. Both compile,
// both derive a store, and both would be provisioned — which is the failure the
// check exists to make loud, because nothing downstream can see it.

@@reventless.spec("TypoStore")

type state = bool
let initialState = false

@schema
type consumedEvent = ProductAdded

let evolve = (_state, _event) => true

@schema
type command =
  | TypoStore({
      productId: string,
      productImage: Reventless.UploadableImage.t,
      productImgae: Reventless.UploadableImage.t,
    })

@schema
type error = ProductNotFound

@schema
type event = TypoStored({productId: string})

let decide = (_state, _command): result<array<event>, error> => Ok([])
