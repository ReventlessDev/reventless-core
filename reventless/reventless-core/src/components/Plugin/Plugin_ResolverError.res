// Runtime-safe resolver error hook.
//
// Fires when a generateCommand resolver receives a command type that cannot be
// decoded against the registered command schema. Fire-and-forget: the hook
// returns unit, async work is the consumer's concern.
//
// Extracted from Plugin_Helpers so the Lambda runtime path (which calls into
// CommandGenerator_Callback) doesn't transitively import Plugin_Helpers' Pulumi
// dependencies.

type resolverErrorInfo = {
  pluginName: string,
  componentName: string,
  /** The GraphQL mutation field / command topic tag that was attempted. */
  attemptedCommandType: string,
  timestamp: string,
}

let onResolverErrorHook: ref<option<resolverErrorInfo => unit>> = ref(None)

let registerOnResolverError = (hook: resolverErrorInfo => unit) => {
  onResolverErrorHook.contents = Some(hook)
}

let clearOnResolverError = () => {
  onResolverErrorHook.contents = None
}
