// ChangeProductName StateChangeSlice.
// Requires product to exist; idempotent when name is unchanged.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({name: string})
  | ProductNameChanged({name: string})
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  ChangeProductName({productId: string, name: string})

@schema
type error =
  | ProductNotFound
  | ProductIsDiscontinued

@schema
type event =
  | ProductNameChanged({productId: string, name: string})

// Legal on a listed product and on an archived one — correcting a name while a
// product is off the shelf is exactly when it wants correcting. Not legal on a
// discontinued one, which is terminal, and it moves the product nowhere.
type lifecycleState = Products.shelfStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | ChangeProductName(_) => Guards([Products.Listed, Products.Archived])
  }
}
