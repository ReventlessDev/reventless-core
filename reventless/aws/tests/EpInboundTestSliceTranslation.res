// Translation fixture paired with EpInboundTestSlice. Rejects non-USD input so the
// routing test exercises the receive reject path — no command is published, so the
// test needs neither SQS nor DynamoDB.

module Spec = EpInboundTestSlice
open Spec

let moduleUrl = "ep-inbound-test://translation"

let translate = (input: externalInput): result<array<(string, command)>, string> =>
  input.currency !== "USD"
    ? Error("Unsupported currency: " ++ input.currency)
    : Ok([(input.sku, AddThing({thingId: input.sku}))])
