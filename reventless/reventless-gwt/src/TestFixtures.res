let id = "id"
let meta = {
  Reventless.Message.service: "service",
  user: "ProjectionTest",
  ip: "ip",
  time: "time",
  msgId: "msgId",
  correlationId: "correlationId",
}

let context = {Reventless.Message.meta, id}

let statusChange = {Reventless.Message.at: context.meta.time, by: context.meta.user}
