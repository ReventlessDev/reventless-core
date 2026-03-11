open FastCSV
open FastCSV_Helpers

parseFile(
  ~path="x.csv",
  ~options={
    Options.headers: Bool(true),
    delimiter: ";",
    //~trim=true,
    //~discardUnmappedColumns=false, ~strictColumnHandling=true,
  },
)
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
