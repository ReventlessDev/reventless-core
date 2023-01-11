let filterEventTopics = (allEventTopics, aggregateNames) =>
  aggregateNames
  ->Belt.Set.String.toArray
  ->Belt.Array.map(aggregateName =>
      try (
        aggregateName,
        allEventTopics->Js.Dict.get(aggregateName)->Belt.Option.getExn,
      ) {
      | exn =>
        Js.log2(
          {j|Util_EventTopic.filterEventTopics: Couldn't find Aggregate $aggregateName in|j},
          allEventTopics,
        );
        raise(exn);
      }
    )
  ->Js.Dict.fromArray;
