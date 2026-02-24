module Make = (Target: ReventlessSpec.EventMapping.Target): (
  ReventlessSpec.EventMapper.Mappings with module Target := Target
) => {
  module type Mapping = ReventlessSpec.EventMapping.T with module Target := Target

  let mappings = []
  let counter = None
}
