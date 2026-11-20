// An operator limits the power one charger may deliver.
@@reventless.spec

@schema
type consumedEvent = ChargerRegistered

@schema
type command = LimitPower({chargerId: ChargerId.t, powerKw: float})

@schema
type error = UnknownCharger

@schema
type event = PowerLimited({chargerId: ChargerId.t, powerKw: float})
