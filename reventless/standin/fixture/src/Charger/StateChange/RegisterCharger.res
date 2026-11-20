// A charger joins the site; the stand-ins play one twin per registered charger.
@@reventless.spec

@schema
type consumedEvent = ChargerRegistered

@schema
type command = RegisterCharger({chargerId: ChargerId.t, name: string, maxPowerKw: float})

@schema
type error = ChargerAlreadyRegistered

@schema
type event = ChargerRegistered({chargerId: ChargerId.t, name: string, maxPowerKw: float})
