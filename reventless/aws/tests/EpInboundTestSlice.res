// Minimal InboundTranslationSlice spec fixture for the DCB entry-point Route 0
// routing test (DcbInboundTranslationRoutingTest). Hand-written — not a plugin
// component, so no folder-based ppx; only the fields
// InboundTranslationSlice_Callback.Make reads at runtime are provided.

let name = "EpInboundTest"
let moduleUrl = "ep-inbound-test://spec"

@schema
type externalInput = {
  sku: string,
  currency: string,
}

@schema
type command = AddThing({thingId: string})

let targetName = "AddThing"
let externalSystem: option<string> = Some("TestFeed")
