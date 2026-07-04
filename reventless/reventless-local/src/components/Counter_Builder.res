// In-memory Counter builder.

module Make = (Bus: LocalBus.T) => {
  module QueryDbStorage = LocalQueryDbStorage.Make(Bus)
  module Api = {
    let api = () => ()
    let apiRole = () => ()
  }
  include ReventlessCore.Counter_Builder.Make(
    QueryDbStorage,
    Api,
    LocalCounterHandler,
  )
}
