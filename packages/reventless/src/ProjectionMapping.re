/*
  module ToGenericSource = (Source: Source) =>
   Mapper.MakeGenericSourceFromEventSource(Source);
 module ToGenericTarget = (Target: Target) =>
   Mapper.MakeGenericTargetFromStateTarget(Target);
 */
module type ProjectionImpl = {
  module Spec: ReventlessSpec.MapperNto1.Spec;
  module Source: ReventlessSpec.ProjectionSpec.Source;
  //module Target: ReventlessSpec.ProjectionSpec.Target;
  type target; // NOTE: to be destructive substituted
  let map: (Source.event, Message.context) => Spec.action(string, target);
};

/* This probably won't be needed
   module Make =
          (
            Impl: ProjectionImpl with module Spec := ReventlessSpec.ProjectionSpec,
          )

            : (
              ReventlessSpec.MapperNto1.Mapping with
                module Spec := ReventlessSpec.ProjectionSpec and
                module Target := ReventlessSpec.Mapper.MakeGenericTargetFromStateTarget(Impl.Target)
          ) => {
     module GenericMappingImpl = {
       module Spec = ReventlessSpec.ProjectionSpec;
       module Source =
         ReventlessSpec.Mapper.MakeGenericSourceFromEventSource(Impl.Source);
       module Target =
         ReventlessSpec.Mapper.MakeGenericTargetFromStateTarget(Impl.Target);
       let map: (Source.t, Message.context) => Spec.action(string, Target.t) = Impl.map;
     };
     include MapperNto1.Mapping(
               ReventlessSpec.ProjectionSpec,
               GenericMappingImpl,
             );
   };
   */

// module Mappings =
//        (Spec: Spec, Target: GenericTarget)
//        : (Mappings with module Spec := Spec and module Target := Target) => {
//   module type Mapping =
//     ReventlessSpec.MapperNto1.Mapping with
//       module Spec := ReventlessSpec.ProjectionSpec and
//       module Target := ReventlessSpec.Mapper.MakeGenericTargetFromStateTarget(Impl.Target);
// };
