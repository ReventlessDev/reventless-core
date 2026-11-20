// A charger reports the energy it delivered since its last reading, through a
// signed door, as a real charger's backend would.
@@reventless.spec

@schema
type externalInput = {
  readingId: string,
  chargerId: string,
  sessionId: string,
  energyWh: float,
  powerW: float,
  at: string,
}

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

let targetName = "RecordReading"
let externalSystem = Some("Chargers")
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []

let endpoint = Some({
  Reventless.InboundTranslationSlice.path: "meter",
  auth: SignedBody({
    header: "X-Signature-256",
    prefix: "sha256=",
    timestampHeader: "X-Signature-Timestamp",
    secret: "chargers",
  }),
})
