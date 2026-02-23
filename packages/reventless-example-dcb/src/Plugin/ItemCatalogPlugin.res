// ItemCatalog DCB plugin — platform-agnostic composition root.
// Wire the DCB event log, state change slices, and view slice using any Platform implementation.
//
// Usage (deploy-time / Pulumi):
//   module Platform = ReventlessAws.Platform.Make(Config)
//   module App = ItemCatalogPlugin.Make(Platform)
//   let eventLog = App.ItemEventLogMaker.make(~name="ItemCatalog")
//   let publishJsons = commandTopic->CommandTopic.operations->...publishJsons
//   let createItem = App.CreateItemSlice.make(~dcbEventLog=eventLog, ~publishJsons)
//   let renameItem = App.RenameItemSlice.make(~dcbEventLog=eventLog, ~publishJsons)
//   let archiveItem = App.ArchiveItemSlice.make(~dcbEventLog=eventLog, ~publishJsons)
//   let itemView = App.ItemViewSlice.make(~dcbEventLog=eventLog)

module Make = (Platform: ReventlessSpec.Platform.T) => {
  module ItemEventLogMaker = Platform.DcbEventLog.Make(ItemEventLog)

  module CreateItemSlice = Platform.StateChangeSlice.Make(CreateItem)
  module RenameItemSlice = Platform.StateChangeSlice.Make(RenameItem)
  module ArchiveItemSlice = Platform.StateChangeSlice.Make(ArchiveItem)

  module ItemViewSlice = Platform.StateViewSlice.Make(ItemView)

  module DcbSpec = ItemEventLog
}
