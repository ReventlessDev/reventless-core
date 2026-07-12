open JestGlobals
open GraphQL_PushPlanner

// Minimal neutral fragments. `stitch` always adds Relay base types + `node`, so we assert on the
// distinctive field names to know which base/fragments landed in each plan.
let mkFragment = (~query: string): Reventless.Plugin.apiSchemaFragment =>
  GraphQL_Stitcher.encode({
    types: [],
    queries: [query],
    mutations: [],
    subscriptions: [],
    subscriptionSources: [],
  })

let adminBase = mkFragment(~query="  Admin_Q: String")
let domainFrag = mkFragment(~query="  Domain_Q: String")
let platformFrag = mkFragment(~query="  Platform_Q: String")

let fragments = [
  {fragment: domainFrag, target: Domain},
  {fragment: platformFrag, target: Platform},
]

let planFor = (plans: array<pushPlan>, api: planTarget): option<pushPlan> =>
  plans->Array.find(p => p.api == api)

describe("GraphQL_PushPlanner.planPushes", () => {
  testSync("split mode: admin base + Platform fragments on the Platform API only", () => {
    let plans = planPushes(~adminBase, ~fragments, ~splitApi=true)
    expect(plans->Array.length)->toBe(2)
    let platform = planFor(plans, PlatformApi)->Belt.Option.getExn
    expect(platform.sdl->String.includes("Admin_Q"))->toBe(true)
    expect(platform.sdl->String.includes("Platform_Q"))->toBe(true)
    expect(platform.sdl->String.includes("Domain_Q"))->toBe(false)
  })

  testSync("split mode: empty base + Domain fragments on the Domain API only (no admin)", () => {
    let plans = planPushes(~adminBase, ~fragments, ~splitApi=true)
    let domain = planFor(plans, DomainApi)->Belt.Option.getExn
    expect(domain.sdl->String.includes("Domain_Q"))->toBe(true)
    expect(domain.sdl->String.includes("Admin_Q"))->toBe(false)
    expect(domain.sdl->String.includes("Platform_Q"))->toBe(false)
  })

  testSync("unified mode: one Domain API push with admin base + ALL fragments", () => {
    let plans = planPushes(~adminBase, ~fragments, ~splitApi=false)
    expect(plans->Array.length)->toBe(1)
    let only = plans->Array.getUnsafe(0)
    expect(only.api == DomainApi)->toBe(true)
    expect(only.sdl->String.includes("Admin_Q"))->toBe(true)
    expect(only.sdl->String.includes("Domain_Q"))->toBe(true)
    expect(only.sdl->String.includes("Platform_Q"))->toBe(true)
  })

  testSync("empty registry still pushes the admin base (split → Platform API)", () => {
    let plans = planPushes(~adminBase, ~fragments=[], ~splitApi=true)
    let platform = planFor(plans, PlatformApi)->Belt.Option.getExn
    expect(platform.sdl->String.includes("Admin_Q"))->toBe(true)
    let domain = planFor(plans, DomainApi)->Belt.Option.getExn
    expect(domain.sdl->String.includes("Admin_Q"))->toBe(false)
  })
})
