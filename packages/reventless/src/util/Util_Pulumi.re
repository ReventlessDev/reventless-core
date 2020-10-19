module Output = {
  module Async = {
    type t('a) = (Pulumi.Output.t('a), (. Pulumi.Output.t('a)) => unit);

    let make = () => {
      let (set, output) = {
        let set = ref((. _eventCollector) => ());
        let output =
          Js.Promise.make((~resolve, ~reject as _) => set := resolve)
          ->Pulumi.Output.fromPromise
          ->Pulumi.Output.unwrap;
        (set^, output);
      };
      (output, set);
    };
  };
};
