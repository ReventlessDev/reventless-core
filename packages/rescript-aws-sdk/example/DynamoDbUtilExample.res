open DynamoDb_Util

Console.log("----MARSHALL----")
type a = {a: int, b: bool}
let r = MarshallOptions.topLevelContainerConverted(~wrapNumbers=true)
let test = {a: 42, b: true}->marshall(~options=r)
Console.log(test) // `{ M: { a: { N: '42' }, b: { BOOL: true } } }`

Console.log("----UNMARSHALL----")
let num = {number: "42"}
let bool = {bool: true}
let dict = [("a", num), ("b", bool)]->Dict.fromArray
let result = unmarshallDict(dict)
Console.log(result)
let attrV = {map: dict}
let result = unmarshall(attrV)
Console.log(result)
let result = unmarshall(bool)
Console.log(result)
