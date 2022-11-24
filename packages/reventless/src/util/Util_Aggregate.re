let allEventTopics = allAggregates =>
  Js.Dict.map(
    (. aggregate) => aggregate##eventLog##eventTopic,
    allAggregates,
  );

let filterEventTopics = (allAggregates, aggregateNames) =>
  aggregateNames
  ->Belt.Set.String.toArray
  ->Belt.Array.keepMap(aggregateName =>
      allAggregates
      ->Js.Dict.get(aggregateName)
      ->Belt.Option.map(aggregateOutput =>
          (aggregateName, aggregateOutput##eventLog##eventTopic)
        )
    )
  ->Js.Dict.fromArray;
