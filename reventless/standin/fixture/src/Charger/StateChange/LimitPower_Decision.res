@@reventless.decision

type state = {registered: bool}

let initialState = {registered: false}

let evolve = (_state, event) =>
  switch event {
  | ChargerRegistered => {registered: true}
  }

let decide = (state, command) =>
  switch command {
  | LimitPower({chargerId, powerKw}) =>
    state.registered ? Ok([PowerLimited({chargerId, powerKw})]) : Error(UnknownCharger)
  }
