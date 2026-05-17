// Module type for a cross-stack output projection.
//
// Implementations declare which fields they need from the remote stack's field manifest
// and provide a decoder for the raw stack export JSON.  The query engine calls
// `fromJson` on each individual export item only after field validation passes.
//
// Usage example (Task projection that only needs name and bucketNames):
//
//   module BucketQuery = ReventlessInterop.Query.Task.Make({
//     @schema
//     type t = { name: string, bucketNames: dict<string> }
//
//     let requiredFields = ["name", "bucketNames"]
//     let optionalFields = []
//
//     let fromJson = json =>
//       try {
//         let r = json->S.parseOrThrow(~to=ReventlessInterop.Task.resolvedOutputsSchema)
//         Ok({ name: r.name, bucketNames: r.bucketNames->Option.getOr(Dict.make()) })
//       } catch {
//       | exn => Error(exn->Js.Exn.asJsExn->Option.flatMap(Js.Exn.message)->Option.getOr("parse error"))
//       }
//   })
module type T = {
  // The projected type produced by this module.
  type t

  // Fields that must be present in the publisher's field manifest.
  // Absence of any required field causes a Compat.MissingRequiredField error at deploy time.
  let requiredFields: array<string>

  // Fields this projection requests but tolerates being absent.
  // The corresponding field in `t` must be option-typed when listed here.
  let optionalFields: array<string>

  // Decode a single stack export item from raw JSON.
  // Called only after field validation passes.
  let fromJson: JSON.t => result<t, string>
}
