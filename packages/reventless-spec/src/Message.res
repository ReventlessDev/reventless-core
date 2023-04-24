@decco
type service = string

@decco
type meta = {
  service: service,
  time: string,
  ip: string,
  user: string,
  msgId: string,
  correlationId: string,
}

@decco
type context = {
  id: string,
  meta: meta,
}

@decco
type event'<'id, 'event> = {
  id: 'id,
  meta: meta,
  event: 'event,
}

let invalidEvent = () => Js.Exn.raiseError("Invalid Event")

@decco
type statusChange = {
  at: string,
  by: string,
}

@decco
type command'<'id, 'command> = {
  id: 'id,
  meta: meta,
  command: 'command,
}

@decco
type commandJson = {
  id: string,
  meta: meta,
  commandJson: Js.Json.t,
  delay: option<int>,
}
