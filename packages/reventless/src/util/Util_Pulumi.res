module Output = {
  module Async = {
    type t<'a> = (Pulumi.Output.t<'a>, Pulumi.Output.t<'a> => unit)

    let make = () => {
      let (set, output) = {
        let set = ref(_eventCollector => ())
        let output =
          Promise.make((resolve, _) => set := resolve)
          ->Pulumi.Output.fromPromise
          ->Pulumi.Output.unwrap
        (set.contents, output)
      }
      (output, set)
    }
  }
}

module ComponentResourceOptions = {
  let ofCustomResourceOptions = (customResourceOpts: Pulumi.CustomResourceOptions.t) => {
    Pulumi.ComponentResource.id: ?customResourceOpts.id,
    dependsOn: ?customResourceOpts.dependsOn,
    parent: ?customResourceOpts.parent,
    protect: ?customResourceOpts.protect,
    provider: ?customResourceOpts.provider,
  }

  let toCustomResourceOptions = (componentResourceOpts: Pulumi.ComponentResource.options) => {
    Pulumi.CustomResourceOptions.id: ?componentResourceOpts.id,
    dependsOn: ?componentResourceOpts.dependsOn,
    parent: ?componentResourceOpts.parent,
    protect: ?componentResourceOpts.protect,
    provider: ?componentResourceOpts.provider,
  }
}
