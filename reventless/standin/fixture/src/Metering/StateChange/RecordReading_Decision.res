@@reventless.decision

type state = {recorded: bool}

let initialState = {recorded: false}

let evolve = (_state, event) =>
  switch event {
  | ReadingRecorded => {recorded: true}
  }

let decide = (state, command) =>
  switch command {
  | RecordReading(r) =>
    state.recorded
      ? Ok([])
      : Ok([
          ReadingRecorded({
            readingId: r.readingId,
            chargerId: r.chargerId,
            sessionId: r.sessionId,
            energyWh: r.energyWh,
            powerW: r.powerW,
            at: r.at,
          }),
        ])
  }
