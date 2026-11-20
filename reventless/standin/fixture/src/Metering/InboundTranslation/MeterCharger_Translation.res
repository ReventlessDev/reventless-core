@@reventless.translation

let translate = async (input: externalInput, ~capabilities as _, ~caller as _) =>
  input.energyWh < 0.
    ? Error("energyWh must not be negative")
    : Ok([
        (
          input.readingId,
          RecordReading({
            readingId: input.readingId,
            chargerId: input.chargerId,
            sessionId: input.sessionId,
            energyWh: input.energyWh,
            powerW: input.powerW,
            at: input.at,
          }),
        ),
      ])
