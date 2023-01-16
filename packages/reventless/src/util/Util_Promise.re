type result('a) = {
  .
  "status": string,
  "value": option('a),
  "reason": option(Js.Promise.error),
};

let filterRejected = results =>
  results
  ->Belt.Array.mapWithIndex((idx, result) => (idx, result))
  ->Belt.Array.keep(((_, result)) => result##status == "rejected")
  ->Belt.Array.map(((idx, result)) =>
      (
        idx,
        result##reason
        ->Belt.Option.map(reason => reason->Util_Error.ofPromise##message)
        ->Belt.Option.getWithDefault("Unknown error"),
      )
    );

[@val] [@scope "Promise"]
external allSettled:
  array(Js.Promise.t('a)) => Js.Promise.t(array(result('a))) =
  "allSettled";
