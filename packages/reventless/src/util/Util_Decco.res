module Json = {
  let variantName: Js.Json.t => option<string> = json =>
    json
    ->Js.Json.decodeArray
    ->Belt.Option.flatMap(evtArr => evtArr->Belt.Array.get(0))
    ->Belt.Option.flatMap(evt => evt->Js.Json.decodeString)
}
