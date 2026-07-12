// Generic, provider-neutral push planner for the event-sourced API-schema fragment registry.
//
// Given the fragments currently in the ApiFragmentRegistry (each tagged with the API it belongs to)
// it groups them by target and produces one stitched-SDL push plan per API, honouring split vs.
// unified mode. It encodes the SAME base-selection rules the deploy-time push
// (`reventless-aws Platform.preResolversSchemaHook`) applies, so the reactive single writer stays
// consistent with the deploy path:
//   - split mode: the Platform API carries the admin base + Platform-target fragments; the Domain
//     API carries an EMPTY base + Domain-target fragments (admin lives only on the Platform API).
//   - unified mode: a single API carries the admin base + ALL fragments regardless of target.
//
// Neutral SDL only — the AWS adapter injects @aws_subscribe per plan and pushes each to the
// matching AppSync API id; the local platform (scope 2) will consume the same plans in-process.

open Reventless.Plugin

type targetedFragment = {
  fragment: apiSchemaFragment,
  target: apiTarget,
}

// The destination API of a push plan. In unified mode every fragment collapses onto `DomainApi`
// (the single shared API); the AWS adapter maps `PlatformApi` → the Platform AppSync id and
// `DomainApi` → the Domain AppSync id.
@schema
type planTarget = DomainApi | PlatformApi

type pushPlan = {
  api: planTarget,
  // Stitched neutral SDL for that API (admin/empty base + the target's fragments).
  sdl: string,
}

// An empty base fragment — the Domain API's base in split mode (admin is on the Platform API).
let emptyBase: apiSchemaFragment = GraphQL_Stitcher.encode({
  types: [],
  queries: [],
  mutations: [],
  subscriptions: [],
  subscriptionSources: [],
})

let planPushes = (
  ~adminBase: apiSchemaFragment,
  ~fragments: array<targetedFragment>,
  ~splitApi: bool,
): array<pushPlan> =>
  if splitApi {
    let platformFrags =
      fragments->Array.filter(f => f.target == Platform)->Array.map(f => f.fragment)
    let domainFrags = fragments->Array.filter(f => f.target == Domain)->Array.map(f => f.fragment)
    [
      {
        api: PlatformApi,
        sdl: GraphQL_Stitcher.stitch(~baseFragment=adminBase, ~pluginFragments=platformFrags),
      },
      {
        api: DomainApi,
        sdl: GraphQL_Stitcher.stitch(~baseFragment=emptyBase, ~pluginFragments=domainFrags),
      },
    ]
  } else {
    let allFrags = fragments->Array.map(f => f.fragment)
    [{api: DomainApi, sdl: GraphQL_Stitcher.stitch(~baseFragment=adminBase, ~pluginFragments=allFrags)}]
  }
