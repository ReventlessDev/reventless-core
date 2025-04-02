// TODO

// module type Spec = {
//   module type Source;
//   module type Target;
//   // module ToGenericSource: (Source) => GenericSource;
//   // module ToGenericTarget: (Target) => GenericTarget;
//   type action('a);
//   type abstractAction;
//   let toAbstractAction:
//     (
//       action('a),
//       Js.Json.t => Belt.Result.t('a, Decco.decodeError),
//       'a => Js.Json.t
//     ) =>
//     abstractAction;
// };
// module type MappingImpl = {
//   module Spec: Spec; // to be removed via destructive replace in functor call
//   module Source: GenericSource;
//   module Target: GenericTarget;
//   [@decco]
//   type source;
//   [@decco]
//   type target;
//   let map: (source, ReventlessSpec.Message.context) => Spec.action(target);
// };
//   module type Mapping = {
//     module Spec: Spec; // to be removed via destructive replace in functor call
//     module Source: GenericSource;
//     let targetName: string;
//     let map: Js.Json.t => Spec.action(Js.Json.t);
//   };
//   module Mapping =
//          (
//            Spec: Spec,
//            Source: Spec.Source,
//            Target: Spec.Target,
//            Impl: MappingImpl with module Spec := Spec and
//                           type source := Spec.ToGenericSource(Source).t and
//                type target := Spec.ToGenericTarget(Target).t,
//          )
//            : (
//              Mapping with
//                module Spec := Spec and
//                module Source := Spec.ToGenericSource(Impl.Source)
//          ) => {
//     module Source = Spec.ToGenericSource(Impl.Source);
//     module Target = Spec.ToGenericTarget(Impl.Target);
//     let targetName = Target.name;
//     let map = json => {
//       switch (
//         json->ReventlessSpec.Message.context_decode,
//         json->Source.decode,
//       ) {
//       | (Ok(context), Ok(source)) =>
//         source
//         ->Impl.map(context)
//         ->Spec.toAbstractAction(Target.decode, Target.encode)
//       | _ =>
//         Js.Exn.raiseError(
//           "Couldn't decode source:" ++ json->Js.Json.stringify,
//         )
//       };
//     };
//   };
//   module type Mappings = {
//     module Spec: Spec; // to be removed via destructive replace in functor call
//     module Source: GenericSource; // to be removed via destructive replace in functor call
//     module type Mapping =
//       Mapping with module Spec := Spec and module Source := Source;
//     let mappings: array(module Mapping);
//   };
//   module type Mapper = {
//     module Spec: Spec; // to be removed via destructive replace in functor call
//     let map:
//       (~targetName: option(string), Js.Json.t) =>
//       array(Spec.action(Js.Json.t));
//   };
//   module Mapper =
//          (
//            Spec: Spec,
//            Source: GenericSource,
//            Mappings:
//              Mappings with module Spec := Spec and module Source := Source,
//          )
//          : (Mapper with module Spec := Spec) => {
//     let findMappings = (targetNameOpt, mappings) =>
//       targetNameOpt->Belt.Option.mapWithDefault([||], targetName =>
//         mappings->Array.filter((module Mapping: Mappings.Mapping) =>
//           Mapping.targetName == targetName
//         )
//       );
//     let map = (~targetName, json) =>
//       findMappings(targetName, Mappings.mappings)
//       ->Array.filterMap((module Mapping: Mappings.Mapping) =>
//           try (Some(json->Mapping.map)) {
//           | exn =>
//             Js.log2(
//               "Mapping failed:",
//               exn->Js.Exn.asJsExn->Belt.Option.map(Js.Exn.message),
//             );
//             None;
//           }
//         );
//   };

