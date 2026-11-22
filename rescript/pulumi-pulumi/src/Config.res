/** @pulumi/pulumi/Config
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/classes/Config.html
*/
type t

@module("@pulumi/pulumi") @new
external make: option<string> => t = "Config"

@send external require: (t, string) => 'value = "require"
@send external get: (t, string) => option<'value> = "get"
/** A secret config value, kept encrypted in state and redacted in output. Throws
    when the key is unset. */
@send external requireSecret: (t, string) => Output.t<string> = "requireSecret"
/** The secret under `key`, or nothing. Nullable rather than `option`: an `Output`
    is a proxy, and unwrapping an option of one corrupts it. */
@send
external getSecret: (t, string) => Nullable.t<Output.t<string>> = "getSecret"
// TODO: add Config.get with StringConfigOptions parameter - see: @pulumi/pulumi/config.d.ts

// getObject<T>(key: string): T | undefined;
@send external getObject: (t, string) => option<'obj> = "getObject"
