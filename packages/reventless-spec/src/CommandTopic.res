type outputs = {"resources": array<Adapter.resource>}

type publish<'id, 'command> = (. Message.command'<'id, 'command>) => Js.Promise.t<unit>
type publishJsons = (. array<Message.commandJson>) => Js.Promise.t<unit>
