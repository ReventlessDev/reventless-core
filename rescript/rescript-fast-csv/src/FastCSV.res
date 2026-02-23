/*** Bindings for FastCSV library
    https://github.com/C2FO/fast-csv/blob/HEAD/docs/parsing.md
*/

module Options = {
  @unboxed
  type headers = Bool(bool) | String(array<string>)
  type t = {
    /** default: true */
    objectMode?: bool,
    /** default: "," */
    delimiter?: string,
    /** default: '"' */
    quote?: Nullable.t<string>,
    /** default: '"' */
    escape?: string,
    /** default: false  | this could also be array(string), see setHeaders(t, array(string) */
    headers?: headers,
    /** default: false */
    renameHeaders?: bool,
    /** default: false */
    ignoreEmpty?: bool,
    /** default: null */
    comment?: string,
    /** default: false */
    discardUnmappedfolumns?: bool,
    /** default: false */
    strictColumnHandling?: bool,
    /** default: false */
    trim?: bool,
    /** default: false */
    rtrim?: bool,
    /** default: false */
    ltrim?: bool,
  }
}

/** Parser object */
type csvParserStream
type rowCount = int
type row = dict<string>
type rowNumber = int
type reason = string

type calledBack

/** Callback to be used for potentially async validation
 *  params:
 *    - a js Error object or null if there was no error
 *    - bool if given record is valid
 *    - reason, why the given record was invalid
 */
type callback = (Nullable.t<JsExn.t>, bool, option<reason>) => calledBack
type validation = (row, callback) => calledBack

type transformCalledBack
type transformCallback = (Nullable.t<JsExn.t>, option<row>) => transformCalledBack
type transformation = (row, transformCallback) => transformCalledBack

type importerValidation = row => result<unit, string>

/** Create a parser for a given filename and options
  example:
  ```rescript
    parseFile(
      ~path=\"x\",
      ~options=
        {
          Options.headers: Bool(true),
          delimiter: ";"
        }
    )
  ```
*/
@module("fast-csv")
external parseFile: (~path: string, ~options: Options.t=?) => csvParserStream = "parseFile"

/** Create a parser for a given node stream (readable) */
@module("fast-csv")
external parseStream: (~stream: NodeStreams.Readable.t, ~options: Options.t=?) => csvParserStream =
  "parseStream"

/** Register a validation function
  the first row validating to false, will be passed to the onInvalid handler
  example:
  ```rescript
    parseFile(~path="x")
    -> validate((_row, callback) =>
        callback -> toInvalid(\"reason for being invalid\")
       )
  ```
*/
@send
external validate: (csvParserStream, validation) => csvParserStream = "validate"

/** Transform a row
  example:
  ```rescript
    parseFile(~path="x")
    -> transform((row, cb) => {
          Dict.delete(row, \"\"); /* remove property with empty name from row */
          cb |> toValidTransformation(row); /* state a successfull transformation */
        })
  ```
*/
@send
external transform: (csvParserStream, transformation) => csvParserStream = "transform"

/** Register a handler to be called if the parser encounters an error
  example:
  ```rescript
    parseFile(~path="x")
    -> onError(err => err -> Js.Exn.message -> Console.log2("error during parsing:"))
  ```
*/
@send
external onError: (csvParserStream, @as("error") _, JsExn.t => unit) => csvParserStream = "on"

/** Register a handler to be called if a data-set were parsed and evaluated as valid
  example:
  ```rescript
    parseFile(~path="x"))
    -> onData(row => row -> Console.log2("parsed line:"))
  ```
*/
@send
external onData: (csvParserStream, @as("data") _, row => unit) => csvParserStream = "on"

/** Register a handler to be called if the parsing has been completed
  example:
  ```rescript
    parseFile(~path="x"))
    -> onEnd(rowCount => Console.log(`${rowCount->RescriptCore.Int.toString} rows parsed`))
  ```
*/
@send
external onEnd: (csvParserStream, @as("end") _, rowCount => unit) => csvParserStream = "on"

/** Register handler to be called if a data-set is invalid
  example:
  ```rescript
    parseFile(~path="x")
    -> validate((_row, callback) =>
        callback -> toInvalid("reason for being invalid")
       )
    -> onInvalid((row, rowNumber, reason) =>
        switch (reason) {
          | None => Console.log2(`line (${rowNumber->RescriptCore.Int.toString}) has too many/view records:`, row)
          | Some(reason) => Console.log2(`line (${rowNumber->RescriptCore.Int.toString}) is invalid: ${reason}`, row)
        }
       )
  ```
*/
@send
external onInvalid: (
  csvParserStream,
  @as("data-invalid") _,
  (row, rowNumber, option<reason>) => unit,
) => csvParserStream = "on"

/* *****************************
 * HELPER FUNCTIONS           *
 ***************************** */

/** Construct a js Error object from a string
  TODO: hide behind an interface definition
 */
@new
external makeError: string => JsExn.t = "Error"

/** Call the validation-callback function for an invalid data-set */
let toInvalid: (callback, reason) => calledBack = (cb, reason) =>
  cb(Nullable.null, false, Some(reason))

/** Call the validation-callback function for a valid data-set */
let toValid: callback => calledBack = cb => cb(Nullable.null, true, None)

/** Call the validation-callback function for an error in the data-set */
let toError: (callback, reason) => calledBack = (cb, reason) =>
  cb(Nullable.make(makeError(reason)), false, Some(reason))

/** Call the transformation-callback function for a valid transformation */
let toValidTransformation: (transformCallback, row) => transformCalledBack = (cb, row) =>
  cb(Nullable.null, Some(row))

/** Call the transformation-callback function for an error in the transformation */
let toErrorTransformation: (transformCallback, reason) => transformCalledBack = (cb, reason) =>
  cb(Nullable.make(makeError(reason)), None)

/** Register multiple validation-functions, which will be called separately
  The first reason of invalidation will be passed along with the data-invalid event
  example:
  ```rescript
    let validations = [
      (_row, cb) => cb -> toValid,
      (_row, cb) => cb -> toInvalid("invalid"),
      (_row, cb) => cb -> toError("something went wrong")
    ];
    parseFile(~path="x"))
    -> validateMultiple(validations)
  ```
*/
let validateMultiple: (array<validation>, csvParserStream) => csvParserStream = (
  validations,
  parser,
) => validations->Array.reduce(parser, (parser', validation) => parser'->validate(validation))

/** Add callback for validation to Result - to be used in validation function
  TODO: hide behind an interface definition
*/
let fromImporterValidation: importerValidation => validation = validation =>
  (row, cb) =>
    switch row->validation {
    | Ok(_) => cb->toValid
    | Error(msg) => cb->toInvalid(msg)
    }

/** Register a single validation function based on result
  example:
  ```rescript
    parseFile(~path="x")
    -> validateResult(_row => Ok())
  ```
*/
let validateResult: (csvParserStream, importerValidation) => csvParserStream = (
  parser,
  validation,
) => parser->validate(validation->fromImporterValidation)

/** Register multiple result based validation functions, which will be called separately
  The first reason of invalidation will be passed along with the data-invalid event
  example:
  ```rescript
    let validations = [
      _row => Ok(),
      _row => Error("something is invalid"),
    ]
    parseFile(~path="x")
    -> validateMultipleResults(validations)
  ```
*/
let validateMultipleResults: (csvParserStream, array<importerValidation>) => csvParserStream = (
  parser,
  validations,
) =>
  validations
  ->Array.map(validation => validation->fromImporterValidation)
  ->validateMultiple(parser)
