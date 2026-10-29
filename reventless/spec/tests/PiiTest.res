open JestGlobals

let encode = (schema, value) => value->Util_Sury.toJson(schema)
let decode = (schema, json) => json->Util_Sury.fromJson(schema)

describe("Pii stored forms", () => {
  testSync("print and parse round-trip all three forms", () => {
    let forms = [
      Pii.Cipher({version: 1, keyId: "k-7", alg: "A256GCM", bytes: "AbC+/="}),
      Pii.ErasedForm({version: 1}),
      Pii.ForgottenForm({version: 1, ref: "/uploads/sub/0b1c.jpg"}),
    ]
    forms->Array.forEach(form =>
      expect(form->Pii.printStored->Pii.parseStored)->toEqual(Some(form))
    )
  })

  testSync("the wire spellings are the ones the plan fixes", () => {
    expect(Pii.printStored(Pii.Cipher({version: 1, keyId: "k", alg: "a", bytes: "b"})))->toBe(
      "enc:v1:k:a:b",
    )
    expect(Pii.printStored(Pii.ErasedForm({version: 1})))->toBe("erased:v1")
    expect(Pii.printStored(Pii.ForgottenForm({version: 1, ref: "r"})))->toBe("ref:v1:r")
  })

  testSync("a ref may hold a colon; a form missing a part does not parse", () => {
    expect(Pii.parseStored("ref:v1:a:b"))->toEqual(Some(Pii.ForgottenForm({version: 1, ref: "a:b"})))
    expect(Pii.parseStored("enc:v1:k::b"))->toEqual(None)
    expect(Pii.parseStored("erased:1"))->toEqual(None)
    expect(Pii.parseStored("ref:v1:"))->toEqual(None)
    expect(Pii.parseStored("Ada Lovelace"))->toEqual(None)
  })
})

describe("Pii.schema, the field codec", () => {
  let name = Pii.schema(S.string)

  testSync("a value round-trips as the plain value, byte for byte", () => {
    expect(encode(name, Pii.Value("Ada")))->toEqual(JSON.Encode.string("Ada"))
    expect(decode(name, JSON.Encode.string("Ada")))->toEqual(Pii.Value("Ada"))
  })

  testSync("a plain string that reads like a form is still a value", () => {
    expect(decode(name, JSON.Encode.string("erased:v1")))->toEqual(Pii.Value("erased:v1"))
    expect(decode(name, JSON.Encode.string("enc:v1:k:a:b")))->toEqual(Pii.Value("enc:v1:k:a:b"))
  })

  testSync("the two markers decode to Erased and Forgotten and encode back", () => {
    expect(decode(name, Pii.wrap(Pii.erasedMarker)))->toEqual(Pii.Erased)
    expect(decode(name, Pii.wrap(Pii.forgottenMarker)))->toEqual(Pii.Forgotten)
    expect(encode(name, Pii.Erased))->toEqual(Pii.wrap(Pii.erasedMarker))
    expect(encode(name, Pii.Forgotten))->toEqual(Pii.wrap(Pii.forgottenMarker))
  })

  testSync("a stored form that was never opened does not decode", () => {
    let decoded = try Ok(decode(name, Pii.wrap("enc:v1:k:a:b"))) catch {
    | _ => Error()
    }
    expect(decoded)->toEqual(Error())
  })

  testSync("a record-typed value is not taken for a marker", () => {
    let address = Pii.schema(S.object(s => s.field("street", S.string)))
    let json = Dict.fromArray([("street", JSON.Encode.string("Main"))])->JSON.Encode.object
    expect(decode(address, json))->toEqual(Pii.Value("Main"))
  })
})

describe("Pii.plain, the provider the framework ships", () => {
  testPromise("seals a value as itself", async () => {
    let sealed = await Pii.plain.seal(
      ~subject="s",
      ~field="name",
      ~forgettable=false,
      JSON.Encode.string("Ada"),
    )
    expect(sealed)->toEqual(Ok(JSON.Encode.string("Ada")))
  })

  testPromise("opens the forms another provider left, and refuses ciphertext", async () => {
    let erased = await Pii.plain.open_(~field="name", Pii.wrap("erased:v1"))
    expect(erased)->toEqual(Ok(Pii.wrap(Pii.erasedMarker)))
    let forgotten = await Pii.plain.open_(~field="photo", Pii.wrap("ref:v1:/uploads/a.jpg"))
    expect(forgotten)->toEqual(Ok(Pii.wrap(Pii.forgottenMarker)))
    let cipher = await Pii.plain.open_(~field="name", Pii.wrap("enc:v1:k:a:b"))
    expect(cipher)->toEqual(Error(Pii.UnknownForm({field: "name"})))
  })

  testSync("is what a process starts with", () =>
    expect(Pii.Provider.get().name)->toBe("plain")
  )
})
