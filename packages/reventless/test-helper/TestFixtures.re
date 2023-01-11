let id = "id@subId";
let meta = {
  Message.service: "service",
  user: "ViewTest",
  ip: "ip",
  time: "time",
  msgId: "msgId",
  correlationId: "correlationId",
};

let context = {Message.meta, id};

let statusChange = {Message.at: context.meta.time, by: context.meta.user};
