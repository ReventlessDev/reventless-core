@schema
type record = {
  a: @s.meta({description: "aaa"}) string,
  b: string,
}

@schema
type variant = | @s.meta({description: "QQQ"}) Q(int) | @s.meta({description: "XXX"}) X | Y

Console.log2("Record:", recordSchema->S.toInputJSONSchemaOrThrow->JSON.stringifyAny(~space=2))
Console.log2("Variant:", variantSchema->S.toInputJSONSchemaOrThrow->JSON.stringifyAny(~space=2))
