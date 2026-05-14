// SDL types and JSON encoder for the Platform_UIFragments GraphQL query.
// Shared between the in-memory adapter (which resolves from the in-process
// UIFragmentRegistry QueryDb) and the AWS adapter (which scans the
// UIFragmentRegistry DynamoDB table). Both adapters use this encoder so the
// wire shape is byte-identical and a single client query string works against
// either.

open Reventless.Plugin

let sdlTypes: array<string> = [
  `type Platform_UIPanel {\n  fragmentId: String!\n  title: String!\n  description: String!\n  positions: [String!]!\n  requiredAccess: String\n}`,
  `type Platform_UIMenuEntry {\n  label: String!\n  icon: String\n  group: String\n  sortOrder: Int!\n}`,
  `type Platform_UIPage {\n  fragmentId: String!\n  title: String!\n  menuEntry: Platform_UIMenuEntry!\n  requiredAccess: String\n}`,
  `type Platform_UIFragmentEntry {\n  pluginId: String!\n  remoteEntryUrl: String!\n  panels: [Platform_UIPanel!]!\n  pages: [Platform_UIPage!]!\n  registeredAt: String!\n  updatedAt: String!\n}`,
]

let sdlQueryField: string = `  Platform_UIFragments: [Platform_UIFragmentEntry!]!`

let encodeStrings = (ss: array<string>): JSON.t =>
  ss->Array.map(JSON.Encode.string)->JSON.Encode.array

let encodePanel = (p: panelManifestEntry): JSON.t =>
  Dict.fromArray([
    ("fragmentId", JSON.Encode.string(p.fragmentId)),
    ("title", JSON.Encode.string(p.title)),
    ("description", JSON.Encode.string(p.description)),
    ("positions", encodeStrings(p.positions)),
    ("requiredAccess", p.requiredAccess->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
  ])->JSON.Encode.object

let encodeMenuEntry = (m: menuEntry): JSON.t =>
  Dict.fromArray([
    ("label", JSON.Encode.string(m.label)),
    ("icon", m.icon->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
    ("group", m.group->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
    ("sortOrder", JSON.Encode.int(m.sortOrder)),
  ])->JSON.Encode.object

let encodePage = (p: pageManifestEntry): JSON.t =>
  Dict.fromArray([
    ("fragmentId", JSON.Encode.string(p.fragmentId)),
    ("title", JSON.Encode.string(p.title)),
    ("menuEntry", encodeMenuEntry(p.menuEntry)),
    ("requiredAccess", p.requiredAccess->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
  ])->JSON.Encode.object

let encodeUIFragmentEntry = (entry: UIFragmentRegistryReadModelSpec.state): JSON.t =>
  Dict.fromArray([
    ("pluginId", JSON.Encode.string(entry.pluginId)),
    ("remoteEntryUrl", JSON.Encode.string(entry.remoteEntryUrl)),
    ("panels", entry.panels->Array.map(encodePanel)->JSON.Encode.array),
    ("pages", entry.pages->Array.map(encodePage)->JSON.Encode.array),
    ("registeredAt", JSON.Encode.string(entry.registeredAt)),
    ("updatedAt", JSON.Encode.string(entry.updatedAt)),
  ])->JSON.Encode.object
