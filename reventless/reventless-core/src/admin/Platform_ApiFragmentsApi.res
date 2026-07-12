// SDL type and JSON encoder for the Platform_ApiFragments GraphQL query — the
// deploy-facing status surface of the API-schema fragment registry. Shared
// between the in-memory adapter (which resolves from the in-process ApiFragments
// StateViewSlice QueryDb) and the AWS adapter (which scans the ApiFragments
// DynamoDB table), so the wire shape is byte-identical and one client query
// string works against either.
//
// The deploy waiter polls this to confirm its plugin's fragment reached ACTIVE
// (pushStatus "ok") or to surface a stitch error (pushStatus "error" +
// pushMessage). It exposes status only — NOT the encoded SDL, which the waiter
// does not need.

let sdlTypes: array<string> = [
  `type Platform_ApiFragmentEntry {\n  pluginId: String!\n  apiTarget: String!\n  pushStatus: String!\n  pushMessage: String!\n  pushedAt: String!\n  registeredAt: String!\n  updatedAt: String!\n}`,
]

let queryFieldName: string = "Platform_ApiFragments"

let sdlQueryField: string = `  ${queryFieldName}: [Platform_ApiFragmentEntry!]!`

let encodeApiFragmentEntry = (entry: ApiFragments.state): JSON.t =>
  Dict.fromArray([
    ("pluginId", JSON.Encode.string(Plugin.name(entry.pluginId))),
    // apiTarget is a payload-less variant — its schema serializes to the bare
    // JSON string "Domain" / "Platform".
    ("apiTarget", entry.apiTarget->S.reverseConvertToJsonOrThrow(Reventless.Plugin.apiTargetSchema)),
    ("pushStatus", JSON.Encode.string(entry.pushStatus)),
    ("pushMessage", JSON.Encode.string(entry.pushMessage)),
    ("pushedAt", JSON.Encode.string(entry.pushedAt)),
    ("registeredAt", JSON.Encode.string(entry.registeredAt)),
    ("updatedAt", JSON.Encode.string(entry.updatedAt)),
  ])->JSON.Encode.object
