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

/**
Pure error recovery function called by the aggregate runtime when `execute` or `create`
returns an error.

Returns a list of compensating events to emit instead of propagating the error.
Return an empty array to silently discard the failed command.

@example
```rescript
let onError: Handler.errorHandler<Category.error, Category.command, Category.event> =
  (error, _cmd, _ctx) => switch error {
    | CategoryAlreadyExists => [] // silently discard
    | CategoryNotFound => []
    | CategoryAlreadyArchived => []
  }
```
*/
type errorHandler<'error, 'command, 'event> = ('error, 'command, Message.context) => array<'event>
