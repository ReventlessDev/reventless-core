/** @pulumi/pulumi/ComponentResourceOptions
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/classes/StackReference.html
*/
type t

@module("@pulumi/pulumi") @new
external make: string => t = "StackReference"

@module("@pulumi/pulumi") @new
external makeWithName: (string, {"name": string}) => t = "StackReference"

@send
external getOutput: (t, string) => Output.t<option<'a>> = "getOutput"

@send
external requireOutput: (t, Input.t<string>) => Output.t<'a> = "requireOutput"

/** The output's plain value, `undefined` when the stack does not export it.
    Readable in a preview, and outside any `Output.apply`. */
@send
external getOutputValue: (t, string) => promise<option<'a>> = "getOutputValue"

@send @deprecated("JS Api deprecated this function")
external getOutputSync: (t, string) => option<'a> = "getOutputSync"

let get = (dict, key) => dict->Dict.get(key)->Option.getOrThrow
