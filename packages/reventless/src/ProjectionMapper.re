// functor to create specific Mapper for projections
module Spec = ReventlessSpec.ProjectionSpec;

module type Mappings = {
  module Target: ReventlessSpec.ProjectionSpec.Target; // to be removed via destructive replace in functor call
  module type Mapping =
    ProjectionMapping.ProjectionImpl with module Spec := Spec;
  /*
   ReventlessSpec.MapperNto1.Mapping with
     module Spec := Spec and
     module Target := ReventlessSpec.Mapper.MakeGenericTargetFromStateTarget(Target);*/
  let mappings: array(module Mapping);
};

module Make =
       (
         Target: ReventlessSpec.ProjectionSpec.Target,
         Mappings: Mappings with module Target := Target,
       )

         : (
           MapperNto1.Mapper with
             module Spec := Spec and
             module Target := ReventlessSpec.Mapper.MakeGenericTargetFromStateTarget(Target)
       ) => {
  module GenericTarget =
    ReventlessSpec.Mapper.MakeGenericTargetFromStateTarget(Target);
  module GenericMappings = {
    /* TODO: convert
           module type ProjectionMapper.Mappings (see above)
           to
           module type ReventlessSpec.MapperNto1.Mappings
       */
    module type GenericMapping =
      ReventlessSpec.MapperNto1.Mapping with module Spec := Spec;
    module Target = GenericTarget;

    /*(module {
        let sourceName = M.Source.name;
        let map = M.map;
      }: ReventlessSpec.MapperNto1.Mapping)*/
    let mappings: array(module GenericMapping) =
      Mappings.mappings->Belt.Array.map(((module M)) => {
        module GenericMapping = {
          let sourceName = M.Source.name;
          module Source =
            ReventlessSpec.Mapper.MakeGenericSourceFromEventSource(M.Source);
          let map = MapperNto1.makeGenericMap(Source.decode, M.map);
        };
        ((module GenericMapping): (module GenericMapping));
      });
  };
  include MapperNto1.Mapper(Spec, GenericTarget, GenericMappings);
};
