// Runtime handler for the `Platform_UIFragments` admin GraphQL resolver —
// compiled, type-checked ReScript (replaces the inline JS `makeHandlerCode`
// string in Platform_UIFragments_Lambda.res). Runtime-pure (see
// Platform_AdminScan_Ops); the deploy-time module bundles this into an
// EntryPoint archive and re-exports `handler`.
//
// Scans the UiFragments StateViewSlice table (one item per plugin with a
// registered UI-fragment manifest), collapses to the highest version per plugin
// name (platform invariant: one version per plugin), and returns the entries.
// The persisted state is sury-encoded with the same shape the in-memory
// adapter's Platform_UIFragmentsApi.encodeUIFragmentEntry produces, so rows are
// returned as-is (bar the name/version collapse).

@val @scope("process") external processEnv: dict<string> = "env"

let str = (item: dict<JSON.t>, key: string): option<string> =>
  item->Dict.get(key)->Option.flatMap(JSON.Decode.string)

// Build one entry, dropping a row missing pluginId or remoteEntryUrl (mirrors
// the former `!item.pluginId || !item.remoteEntryUrl` guard). `name` is the bare
// plugin name; panels/pages/timestamps default like the JS `|| []` / `|| ""`.
let toEntry = (item: dict<JSON.t>, ~name: string): option<JSON.t> =>
  switch (item->str("pluginId"), item->str("remoteEntryUrl")) {
  | (Some(_), Some(remoteEntryUrl)) if remoteEntryUrl != "" =>
    Some(
      JSON.Encode.object(
        Dict.fromArray([
          ("pluginId", JSON.Encode.string(name)),
          ("remoteEntryUrl", JSON.Encode.string(remoteEntryUrl)),
          ("panels", item->Dict.get("panels")->Option.getOr(JSON.Encode.array([]))),
          ("pages", item->Dict.get("pages")->Option.getOr(JSON.Encode.array([]))),
          ("registeredAt", item->Dict.get("registeredAt")->Option.getOr(JSON.Encode.string(""))),
          ("updatedAt", item->Dict.get("updatedAt")->Option.getOr(JSON.Encode.string(""))),
        ]),
      ),
    )
  | _ => None
  }

let handler = async (_event: JSON.t): array<JSON.t> =>
  switch processEnv->Dict.get("UI_FRAGMENT_RM_TABLE") {
  | None | Some("") =>
    Console.error("Platform_UIFragments: UI_FRAGMENT_RM_TABLE env var not set")
    []
  | Some(table) =>
    let items = await Platform_AdminScan_Ops.scanAll(~tableName=table)
    Platform_AdminScan_Ops.latestByName(items, ~nameVersionOf=item => item->str("pluginId"), ~toEntry)
  }
