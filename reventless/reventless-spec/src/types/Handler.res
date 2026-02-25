// Handler types for application developers
// These define the function signatures for handling commands, events, and errors

type handler<'msg> = 'msg => promise<unit>

type commandHandler<'id, 'command> = Message.command'<'id, 'command> => promise<unit>

type commandsHandler<'id, 'command> = ('id, array<Message.command'<'id, 'command>>) => promise<unit>

type eventsHandler<'id, 'event> = ('id, array<Message.event'<'id, 'event>>) => promise<unit>

type errorHandler<'error, 'command, 'event> = ('error, 'command, Message.context) => array<'event>
