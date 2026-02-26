let publish = (topic, _id, _meta, json) =>
  topic->Util_SNS_Runtime.publish(json->JSON.stringify)->ReventlessCore.Util.Promise.toUnit

let publishFifo = (topic, id, _meta, json) =>
  topic
  ->Util_SNS_Runtime.publishFifo(~messageGroupId=id, ~message=json->JSON.stringify)
  ->ReventlessCore.Util.Promise.toUnit
