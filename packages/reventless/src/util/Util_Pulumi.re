module Output = {
  module Async = {
    type t('a) = (Pulumi.Output.t('a), (. Pulumi.Output.t('a)) => unit);

    [@bs.send]
    external outputFromPromise: Js.Promise.t('a) => Pulumi.Output.t('a) =
      "%identity";

    let make = () => {
      let (set, output) = {
        let set = ref((. _eventCollector) => ());
        let output =
          Js.Promise.make((~resolve, ~reject as _) => set := resolve)
          ->outputFromPromise
          ->Pulumi.Output.unwrap;
        (set^, output);
      };
      (output, set);
    };
  };
};
