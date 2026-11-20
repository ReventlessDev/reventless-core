@@reventless.projection

let project = ({event}) =>
  switch event {
  | ReadingRecorded({sessionId, chargerId, energyWh, powerW}) => [
      UpdateWithDefault(
        sessionId,
        {sessionId, chargerId, energyWh, readings: 1, powerW},
        s => {...s, energyWh: s.energyWh +. energyWh, readings: s.readings + 1, powerW},
      ),
    ]
  }
