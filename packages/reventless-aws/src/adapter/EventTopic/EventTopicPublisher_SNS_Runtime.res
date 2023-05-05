let publish = topic => (. _id, _meta, json) =>
  topic->Util_SNS_Runtime.publish(json->Js.Json.stringify)

let publishFifo = topic => (. id, _meta, json) =>
  topic->Util_SNS_Runtime.publishFifo(~messageGroupId=id, ~message=json->Js.Json.stringify)
