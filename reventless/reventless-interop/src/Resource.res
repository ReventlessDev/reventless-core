// Output.t-free counterpart of Reventless.Adapter.resource.
// Pulumi resolves all pending Output.t<string> fields before serializing stack exports,
// so every field here is a plain string.

@schema
type t = {
  name: string,
  id: string,
  urn: string,
  info: string,
  service: string,
}
