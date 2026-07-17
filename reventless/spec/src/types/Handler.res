// Handler types for application developers.
// These define the function signatures for handling commands, events, and errors.

/** A generic async handler for any message type `'msg`. */
type handler<'msg> = 'msg => promise<unit>

/**
Handler for a single typed command.

@example
```rescript
let handleCategory: Handler.commandHandler<string, Category.command> = async msg => {
  Console.log2("Handling command for", msg.id)
}
```
*/
type commandHandler<'id, 'command> = Message.command'<'id, 'command> => promise<unit>

/**
Handler for a batch of commands sharing the same aggregate ID.
Batches arrive when multiple commands are enqueued for the same ID.
*/
type commandsHandler<'id, 'command> = ('id, array<Message.command'<'id, 'command>>) => promise<unit>

/**
Handler for a batch of events sharing the same aggregate ID.
Used by read model projections and extension points.
*/
type eventsHandler<'id, 'event> = ('id, array<Message.event'<'id, 'event>>) => promise<unit>

