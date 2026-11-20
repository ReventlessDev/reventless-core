// A reading is recorded once: a repeat of the same reading appends nothing.
@@reventless.spec

@schema
type consumedEvent = ReadingRecorded

@schema
type command =
  | RecordReading({
      readingId: string,
      chargerId: string,
      sessionId: string,
      energyWh: float,
      powerW: float,
      at: string,
    })

@schema
type error = unit

@schema
type event =
  | ReadingRecorded({
      @partitionTag readingId: string,
      @noDcbTag chargerId: string,
      @noDcbTag sessionId: string,
      energyWh: float,
      powerW: float,
      at: string,
    })
