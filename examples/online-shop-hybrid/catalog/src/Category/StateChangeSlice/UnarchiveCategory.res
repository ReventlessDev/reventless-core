// UnarchiveCategory StateChangeSlice.
// The way back out of the archive. Requires the category to exist; idempotent if
// it is not archived.
//
// A command rather than a flag a form can flip, because it is the same kind of
// fact `ArchiveCategory` is — someone decided to return this category to the
// catalog — and a `CategoryUnarchived` event is what lets anything downstream
// react to that decision. Only the aggregate's own state says whether it is
// allowed, which is why the check below is on `archived` rather than on who is
// asking.
@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived
  | CategoryUnarchived

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"])) UnarchiveCategory({categoryId: string})

@schema
type error = CategoryNotFound

@schema
type event = CategoryUnarchived({categoryId: string})

type lifecycleState = Categories.shelfStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | UnarchiveCategory(_) => Moves([Categories.Archived], Categories.Listed)
  }
}
