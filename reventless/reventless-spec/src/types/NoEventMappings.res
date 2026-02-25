module Make = (Target: EventMapping.Target): (
  EventMapper.Mappings with module Target := Target
) => {
  module type Mapping = EventMapping.T with module Target := Target
  let mappings = []
  let counter = None
}
