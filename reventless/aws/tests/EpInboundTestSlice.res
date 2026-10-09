// Inbound spec fixture for DcbInboundTranslationRoutingTest. Hand-written, so it
// declares the members the PPX would otherwise inject.

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

type role = Reventless.Role.name
let commandAuthorization = (_: command): Reventless.Authorization.rule<role> => AllowRoles([
  Reventless.Role.make("Admin"),
])
