// Test fixture for a declared singular: the English rule makes `Statu` of `Status`, and `Status`
// its own plural.

@@reventless.spec("Status")

@schema
type consumedEvent = StatusSet({statusId: string, label: string})

@singular("Status") @plural("Statuses") @schema
type state = {statusId: string, label: string}

let project = ({event}: Reventless.StateViewSlice.consumed<consumedEvent>) =>
  switch event {
  | StatusSet({statusId, label}) => [Set(statusId, {statusId, label})]
  }
