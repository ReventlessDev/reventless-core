// ApiFragments read model — the read side of the platform API-schema fragment registry:
// one row per plugin name holding its current fragment plus the outcome of the last schema
// push that included it. Projected off the ApiFragmentRegistry singleton aggregate (keyed by
// pluginId from the event payload, NOT by the aggregate id — the aggregate is a singleton).
// Backs the `Platform_ApiFragments` status query the deploy waiter polls.
//
// `pushStatus` is "pending" from registration/update until the reactive push SideEffect records
// the outcome ("ok" / "error"); `pushMessage`/`pushedAt` are "" until then (plain strings, no
// option fields — matches the aggregate's wire contract).
@@reventless.spec("ApiFragments")

@schema
type state = {
  pluginId: string,
  encoded: string,
  protocol: string,
  apiTarget: Reventless.Plugin.apiTarget,
  registeredAt: string,
  updatedAt: string,
  pushStatus: string,
  pushMessage: string,
  pushedAt: string,
}
