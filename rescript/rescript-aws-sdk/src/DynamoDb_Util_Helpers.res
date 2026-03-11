let unmarshallDict: (~wrapNumbers: bool=?, dict<DynamoDb_Util.attributeValue>) => 'output = (
  ~wrapNumbers=?,
  data,
) => DynamoDb_Util.Raw.unmarshall(data, ~options={?wrapNumbers, convertWithoutMapWrapper: false})

let unmarshall: (~wrapNumbers: bool=?, DynamoDb_Util.attributeValue) => 'output = (~wrapNumbers=?, data) =>
  DynamoDb_Util.Raw.unmarshall(data, ~options={?wrapNumbers, convertWithoutMapWrapper: true})
