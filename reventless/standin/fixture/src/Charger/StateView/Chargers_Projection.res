@@reventless.projection

let project = ({event}) =>
  switch event {
  | ChargerRegistered({chargerId, name, maxPowerKw}) => [
      Set(chargerId, {chargerId, name, maxPowerKw}),
    ]
  }
