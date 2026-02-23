/** @pulumi/pulumi/Config
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/classes/Config.html
*/
type t

@module("@pulumi/pulumi") @new
external make: option<string> => t = "Config"

@send external require: (t, string) => 'value = "require"
@send external get: (t, string) => option<'value> = "get"
// TODO: add Config.get with StringConfigOptions parameter - see: @pulumi/pulumi/config.d.ts

// getObject<T>(key: string): T | undefined;
@send external getObject: (t, string) => option<'obj> = "getObject"
