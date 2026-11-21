// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

// A flow's steps, one per part, under the part's own name.

// Decisions
module LimitPower = ReventlessGwt.Flow_GWT.DecisionStep(LimitPower, LimitPower_Decision)
module RecordReading = ReventlessGwt.Flow_GWT.DecisionStep(RecordReading, RecordReading_Decision)
module RegisterCharger = ReventlessGwt.Flow_GWT.DecisionStep(
  RegisterCharger,
  RegisterCharger_Decision,
)

// Views
module Chargers = ReventlessGwt.Flow_GWT.ViewStep(Chargers, Chargers_Projection)
module Sessions = ReventlessGwt.Flow_GWT.ViewStep(Sessions, Sessions_Projection)

// Ways out
module TellChargerPower = ReventlessGwt.Flow_GWT.OutboundStep(
  TellChargerPower,
  TellChargerPower_Translation,
)

// Ways in
module MeterCharger = ReventlessGwt.Flow_GWT.InboundStep(MeterCharger, MeterCharger_Translation)
