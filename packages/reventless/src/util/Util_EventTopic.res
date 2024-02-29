let filterEventTopics = (allEventTopics, sourceNames) =>
  sourceNames
  ->Belt.Set.String.toArray
  ->Belt.Array.keepMap(sourceName =>
    allEventTopics->Js.Dict.get(sourceName)->Belt.Option.map(eventTopic => (sourceName, eventTopic))
  )
  ->Js.Dict.fromArray
