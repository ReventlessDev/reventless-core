@schema
type service = string

@schema
type meta = {
  service: service,
  time: string,
  ip: string,
  user: string,
  msgId: string,
  correlationId: string,
}

@schema
type context = {
  id: string,
  meta: meta,
}

type event'<'id, 'event> = {
  id: 'id,
  meta: meta,
  event: 'event,
}

let invalidEvent = (reason, event) => Js.log4("Invalid Event (", reason, "), Event:", event)

@schema
type statusChange = {
  at: string,
  by: string,
}

type command'<'id, 'command> = {
  id: 'id,
  meta: meta,
  command: 'command,
}

@schema
type commandJson = {
  id: string,
  meta: meta,
  commandJson: Js.Json.t,
  delay: option<int>,
}
