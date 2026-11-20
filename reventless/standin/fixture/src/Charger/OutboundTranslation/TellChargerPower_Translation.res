@@reventless.translation

let collect = (event, ~sourceId as _) =>
  switch event {
  | PowerLimited({chargerId, powerKw}) => [(chargerId, {chargerId, powerKw})]
  }

// A charger that is not reachable is told again later; one that refuses has said
// its last word.
let translate = async (_id, item: outboundItem, ~capabilities: Reventless.Capabilities.t) =>
  switch await capabilities.devices.tell(
    ~kind="Charger",
    ~instance=item.chargerId,
    ~message="setPower",
    ~body=JSON.Encode.object(Dict.fromArray([("powerKw", JSON.Encode.float(item.powerKw))])),
  ) {
  | Accepted | Refused(_) => Ok(None)
  | NotReachable(why) => Error(why)
  }

let onExhausted = (_id, _item, ~lastError as _) => None
