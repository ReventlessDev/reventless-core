// ApiFragments StateViewSlice — the read side of the platform API-schema fragment
// registry: the current fragment per plugin name plus the outcome of the last schema
// push that included it. Replaces the raw `deploy-schema:*` rows as the durable source
// the single-writer stitch automation and the runtime re-stitcher read, and backs the
// push-status poll of the deploy waiter.
//
// `pushStatus` is "pending" from registration/update until the automation records the
// push outcome ("ok" / "error"); `pushMessage`/`pushedAt` are "" until then (plain
// strings, no option fields — see the producer spec).
@@reventless.spec

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

// Consumes the ApiFragmentRegistry slice's events (from the shared admin DcbEventLog).
// Inline records with the same constructors/fields as the producer's `event` — decodes
// byte-identically and the ppx auto-tags `pluginId`.
@schema
type consumedEvent =
  | ApiFragmentRegistered({
      pluginId: string,
      fragment: Reventless.Plugin.apiSchemaFragment,
      apiTarget: Reventless.Plugin.apiTarget,
      at: string,
    })
  | ApiFragmentUpdated({
      pluginId: string,
      previousFragment: Reventless.Plugin.apiSchemaFragment,
      newFragment: Reventless.Plugin.apiSchemaFragment,
      apiTarget: Reventless.Plugin.apiTarget,
      at: string,
    })
  | ApiFragmentDeregistered({pluginId: string})
  | ApiFragmentPushRecorded({pluginId: string, ok: bool, message: string, at: string})
