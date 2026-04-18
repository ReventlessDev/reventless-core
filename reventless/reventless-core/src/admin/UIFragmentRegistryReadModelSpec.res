@@reventless.spec("UIFragmentRegistry")

open Reventless.Plugin

@schema
type state = {
  pluginId: string,
  remoteEntryUrl: string,
  panels: array<panelManifestEntry>,
  pages: array<pageManifestEntry>,
  registeredAt: string,
  updatedAt: string,
}
