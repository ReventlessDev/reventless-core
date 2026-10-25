@@reventless.decision

// Nothing recorded is open: a role reaches this slice only if it is declared
// self-service. Opening an open role with the same end, or closing a closed one,
// changes nothing and records nothing.

type state =
  | Closed
  | Open(option<Reventless.DateTime.t>)

let initialState = Open(None)

let evolve = (_state, event) =>
  switch event {
  | RegistrationOpened({?until}) => Open(until)
  | RegistrationClosed(_) => Closed
  }

let decide = (state, command) => {
  let role = switch command {
  | OpenRegistration({role}) | CloseRegistration({role}) => role
  }
  if !Admission.isSelfService(role) {
    Error(NotSelfService({role: role}))
  } else {
    switch (state, command) {
    | (Open(current), OpenRegistration({?until})) if current == until => Ok([])
    | (_, OpenRegistration({role, ?until})) => Ok([RegistrationOpened({role, ?until})])
    | (Closed, CloseRegistration(_)) => Ok([])
    | (Open(_), CloseRegistration({role})) => Ok([RegistrationClosed({role: role})])
    }
  }
}
