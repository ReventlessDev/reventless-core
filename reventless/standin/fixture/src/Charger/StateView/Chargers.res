// The chargers on the site: the view a charger stand-in reads its twins from.
@@reventless.spec

module Id = ChargerId

@schema
type consumedEvent = ChargerRegistered({chargerId: ChargerId.t, name: string, maxPowerKw: float})

@schema
type state = {chargerId: ChargerId.t, name: string, maxPowerKw: float}
