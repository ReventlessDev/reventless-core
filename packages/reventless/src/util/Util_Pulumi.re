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

module ComponentResourceOptions = {
  let ofCustomResourceOptions = customResourceOpts => {
    let keys = customResourceOpts->Js.Obj.keys;
    let firstKey = keys->Belt.Array.get(0);
    if (keys->Belt.Array.size <= 1
        && (firstKey == Some("parent") || firstKey == None)) {
      Pulumi.ComponentResource.Options.make(
        ~parent=?customResourceOpts##parent,
        (),
      );
    } else {
      let keysStr = keys->Js.Array2.joinWith(",");
      Js.Exn.raiseError(
        __MODULE__
        ++ ": currently only parent prop supported! keys: "
        ++ keysStr,
      );
    };
  };
};
