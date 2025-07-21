open DynamoDb_Util

Js.Console.log("----MARSHALL----")
type a = {a: int, b: bool}
let r = MarshallOptions.topLevelContainerConverted(~wrapNumbers=true)
let test = {a: 42, b: true}->marshall(~options=r)
Js.Console.log(test) // `{ M: { a: { N: '42' }, b: { BOOL: true } } }`

Js.Console.log("----UNMARSHALL----")
let num = {number: "42"}
let bool = {bool: true}
let dict = [("a", num), ("b", bool)]->Js.Dict.fromArray
let result = unmarshallDict(dict)
Js.Console.log(result)
let attrV = {map: dict}
let result = unmarshall(attrV)
Js.Console.log(result)
let result = unmarshall(bool)
Js.Console.log(result)
