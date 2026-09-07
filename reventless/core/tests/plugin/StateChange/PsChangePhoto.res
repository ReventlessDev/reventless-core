// Test fixture spec for heuristic capability inference.
//
// `photoUrl` matches the stored-object name heuristic but carries no
// `@storageRef` — the case that must produce a warning and no manifest entry.
// `caption` matches nothing, so the scan's silence on it is also exercised.

@@reventless.spec("ChangePhoto")

type state = bool
let initialState = false

@schema
type consumedEvent = OrderPlaced

let evolve = (_state, _event) => true

@schema
type command = ChangePhoto({productId: string, photoUrl: string, caption: string})

@schema
type error = ProductNotFound

// `thumbnail` matches the same name heuristic but IS declared — the case the
// lint must stay silent on, because the declaration already provisions it.
@schema
type event =
  | PhotoChanged({
      productId: string,
      photoUrl: string,
      @storageRef("productPhotos") thumbnail: string,
    })

let decide = (_state, _command): result<array<event>, error> => Ok([])
