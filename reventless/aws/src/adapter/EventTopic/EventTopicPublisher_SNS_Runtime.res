let publish = (topic, _id, _meta, json) =>
  topic->Util_SNS_Runtime.publish(json->JSON.stringify)

let publishFifo = (topic, id, _meta, json) =>
  topic->Util_SNS_Runtime.publishFifo(~messageGroupId=Util_SQS_Runtime.safeGroupId(id), ~message=json->JSON.stringify)
