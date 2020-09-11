let context = {
  Message.meta: {
    service: "service",
    user: "ViewTest",
    ip: "ip",
    time: "time",
    msgId: "msgId",
    correlationId: "correlationId",
  },
  id: "id",
};

let statusChange = {Message.at: context.meta.time, by: context.meta.user};
