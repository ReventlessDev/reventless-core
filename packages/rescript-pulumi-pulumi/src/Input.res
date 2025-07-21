/** @pulumi/pulumi/Input
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/types/Input.html
*/
type t<'a> = {}

@deprecated("use Input.make instead")
external wrap: 'a => t<'a> = "%identity"

external make: 'a => t<'a> = "%identity"

external ofPromise: Js.Promise.t<'a> => t<'a> = "%identity"
