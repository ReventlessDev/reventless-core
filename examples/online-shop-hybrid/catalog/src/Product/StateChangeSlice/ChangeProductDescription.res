// ChangeProductDescription StateChangeSlice.
// Requires product to exist; idempotent when description is unchanged.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({description: string})
  | ProductDescriptionChanged({description: string})
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  ChangeProductDescription({productId: string, description: string})

@schema
type error =
  | ProductNotFound
  | ProductIsDiscontinued

@schema
type event =
  | ProductDescriptionChanged({
      productId: string,
      description: string,
    })

// Legal while the product is on the shelf and while it is archived; refused once
// it is discontinued, which is terminal.
type lifecycleState = Products.shelfStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | ChangeProductDescription(_) => Guards([Products.Listed, Products.Archived])
  }
}
