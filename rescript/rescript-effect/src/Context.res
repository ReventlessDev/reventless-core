// ReScript bindings for Effect Context
//
// Context is an immutable map from typed Tags to service implementations.
// It is the runtime carrier of the 'r (requirements) channel.
//
// Usage pattern:
//   1. Declare a tag: let myTag: Context.tag<MyService.t> = Context.genericTag("MyService")
//   2. Use in effects: Effect.serviceWith(myTag, svc => svc.doThing())
//      → effect type is Effect.t<result, err, MyService.t>
//   3. Satisfy at boundary: Effect.provideService(effect, myTag, liveImpl)
//      → effect type becomes Effect.t<result, err, unit>

// Opaque tag type. The phantom 'a is the service type this tag identifies.
// Two tags with the same string key but different 'a types are distinct at runtime.
type tag<'a>

// Create a new tag identified by the given unique string key.
// The 'a type is set by annotation at the call site:
//   let loggerTag: tag<Logger.t> = Context.genericTag("Logger")
// The key must be globally unique within the application.
@module("effect") @scope("Context")
external genericTag: string => tag<'a> = "GenericTag"
