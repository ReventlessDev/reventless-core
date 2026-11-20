// The energy each charging session delivered, summed from its readings.
@@reventless.spec

@schema
type consumedEvent =
  | ReadingRecorded({
      readingId: string,
      chargerId: string,
      sessionId: string,
      energyWh: float,
      powerW: float,
      at: string,
    })

@schema
type state = {sessionId: string, chargerId: string, energyWh: float, readings: int, powerW: float}
