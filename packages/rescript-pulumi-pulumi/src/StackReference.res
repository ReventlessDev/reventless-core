/** @pulumi/pulumi/ComponentResourceOptions
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/classes/StackReference.html
*/
type t

@module("@pulumi/pulumi") @new
external make: string => t = "StackReference"

@send
external getOutput: (t, string) => Output.t<option<'a>> = "getOutput"

@send
external requireOutput: (t, Input.t<string>) => Output.t<'a> = "requireOutput"

@send @deprecated("JS Api deprecated this function")
external getOutputSync: (t, string) => option<'a> = "getOutputSync"

let get = (dict, key) => dict->Js.Dict.get(key)->Option.getExn
