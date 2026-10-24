@@reventless.decision

// Opening an open scope with the same end, or closing a closed one, changes
// nothing and records nothing.

type state =
  | Closed
  | Open(option<Reventless.DateTime.t>)

let initialState = Closed

let evolve = (_state, event) =>
  switch event {
  | RegistrationOpened({?until}) => Open(until)
  | RegistrationClosed(_) => Closed
  }

let decide = (state, command) =>
  switch (state, command) {
  | (Open(current), OpenRegistration({?until})) if current == until => Ok([])
  | (_, OpenRegistration({scopeId, ?until})) => Ok([RegistrationOpened({scopeId, ?until})])
  | (Closed, CloseRegistration(_)) => Ok([])
  | (Open(_), CloseRegistration({scopeId})) => Ok([RegistrationClosed({scopeId: scopeId})])
  }
