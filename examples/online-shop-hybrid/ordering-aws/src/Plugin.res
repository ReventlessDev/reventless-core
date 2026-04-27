// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.ORDERING_UI_BUNDLE_URL"

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  module Composition = OrderingPlugin.Plugin.Make(Platform)
  let make = () => Composition.make(~uiBundleUrl?)
}
