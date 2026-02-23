open FastCSV

/*
let validationsWithResult: array<'a => result<unit, string>> = [
  _row => Ok(),
  _row => Error("something is invalid"),
]
*/

/*
let validations = [
  (_row, cb) => cb->toValid,
  (_row, cb) => cb->toInvalid("invalid"),
  (_row, cb) => cb->toError("something went wrong"),
]
*/

parseFile(
  ~path="x.csv",
  ~options={
    Options.headers: Bool(true),
    delimiter: ";",
    //~trim=true,
    //~discardUnmappedColumns=false, ~strictColumnHandling=true,
  },
)
/*
   |> validate((_row, result) => result |> toInvalid("test"))
   |> validate((_row, result) => result |> toValid)
   |> validate((_, result) => {
        Console.log("x");
        result |> toValid;
      })
   |> validate((_row, result) => result |> toError("This is not allowed"))
   |> validateResult(_row => Ok())  /* helper function */
   |> validateMultiple(validations)  /* helper function */
   |> validateMultipleResults(validationsWithResult)  /* helper function */
   				*/
//|> validate((_row, result) => result |> toInvalid("test"))
->transform((row, cb) => {
  Dict.delete(row, "")
  cb->toValidTransformation(row)
})
->onData(row => Console.log2("parsed line:", row))
->onInvalid((row, rowNumber, reason) =>
  switch reason {
  | None => Console.log2(`line (${rowNumber->Int.toString}) has too many/view records:`, row)
  | Some(reason) => Console.log2(`line (${rowNumber->Int.toString}) is invalid: ${reason}`, row)
  }
)
->onError(err => Console.log2("error during parsing:", err->JsExn.message))
->onEnd(rowCount => Console.log(`${rowCount->Int.toString} rows parsed`))
->ignore
