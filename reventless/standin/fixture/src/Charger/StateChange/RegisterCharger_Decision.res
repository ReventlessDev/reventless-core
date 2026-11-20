@@reventless.decision

type state = {registered: bool}

let initialState = {registered: false}

let evolve = (_state, event) =>
  switch event {
  | ChargerRegistered => {registered: true}
  }

let decide = (state, command) =>
  switch command {
  | RegisterCharger({chargerId, name, maxPowerKw}) =>
    state.registered
      ? Error(ChargerAlreadyRegistered)
      : Ok([ChargerRegistered({chargerId, name, maxPowerKw})])
  }
