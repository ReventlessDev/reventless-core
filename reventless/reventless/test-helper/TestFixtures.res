let id = "id"
let meta = {
  Message.service: "service",
  user: "ProjectionTest",
  ip: "ip",
  time: "time",
  msgId: "msgId",
  correlationId: "correlationId",
}

let context = {Message.meta, id}

let statusChange = {Message.at: context.meta.time, by: context.meta.user}
