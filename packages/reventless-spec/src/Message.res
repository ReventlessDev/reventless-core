S.enableJson()

@schema
type service = string

@schema
type meta = {
  service: service, // service name that created event or is addressed by command
  time: string, // when message was created
  ip: string, // IP of service that created message
  user: string, // user name that initiated message (if any)
  msgId: string, // unique message id
  correlationId: string, // id of message that caused this message
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

let invalidEvent = (reason, event) => Console.log4("Invalid Event (", reason, "), Event:", event)

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
  commandJson: JSON.t,
  delay?: int,
}
