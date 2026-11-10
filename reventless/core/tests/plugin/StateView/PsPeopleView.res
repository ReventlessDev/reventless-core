// Test fixture for a declared plural: the English rule makes `Persons` of `Person`.

@@reventless.spec("Person")

@schema
type consumedEvent = PersonAdded({personId: string, name: string})

@plural("People") @schema
type state = {personId: string, name: string}

let project = ({event}: Reventless.StateViewSlice.consumed<consumedEvent>) =>
  switch event {
  | PersonAdded({personId, name}) => [Set(personId, {personId, name})]
  }
