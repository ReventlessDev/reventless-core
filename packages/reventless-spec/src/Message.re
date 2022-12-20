[@decco]
type service = string;

[@decco]
type meta = {
  service,
  time: string,
  ip: string,
  user: string,
  msgId: string,
  correlationId: string,
};

[@decco]
type context = {
  id: string,
  meta,
};
