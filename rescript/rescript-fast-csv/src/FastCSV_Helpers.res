/** Call the validation-callback function for an invalid data-set */
let toInvalid: (FastCSV.callback, FastCSV.reason) => FastCSV.calledBack = (cb, reason) =>
  cb(Nullable.null, false, Some(reason))

/** Call the validation-callback function for a valid data-set */
let toValid: FastCSV.callback => FastCSV.calledBack = cb => cb(Nullable.null, true, None)

/** Call the validation-callback function for an error in the data-set */
let toError: (FastCSV.callback, FastCSV.reason) => FastCSV.calledBack = (cb, reason) =>
  cb(Nullable.make(FastCSV.makeError(reason)), false, Some(reason))

/** Call the transformation-callback function for a valid transformation */
let toValidTransformation: (FastCSV.transformCallback, FastCSV.row) => FastCSV.transformCalledBack = (cb, row) =>
  cb(Nullable.null, Some(row))

/** Call the transformation-callback function for an error in the transformation */
let toErrorTransformation: (FastCSV.transformCallback, FastCSV.reason) => FastCSV.transformCalledBack = (cb, reason) =>
  cb(Nullable.make(FastCSV.makeError(reason)), None)

/** Add callback for validation to Result - to be used in validation function */
let fromImporterValidation: FastCSV.importerValidation => FastCSV.validation = validation =>
  (row, cb) =>
    switch row->validation {
    | Ok(_) => cb->toValid
    | Error(msg) => cb->toInvalid(msg)
    }

/** Register multiple validation-functions, which will be called separately */
let validateMultiple: (array<FastCSV.validation>, FastCSV.csvParserStream) => FastCSV.csvParserStream = (
  validations,
  parser,
) => validations->Array.reduce(parser, (parser', validation) => parser'->FastCSV.validate(validation))

/** Register a single validation function based on result */
let validateResult: (FastCSV.csvParserStream, FastCSV.importerValidation) => FastCSV.csvParserStream = (
  parser,
  validation,
) => parser->FastCSV.validate(validation->fromImporterValidation)

/** Register multiple result based validation functions, which will be called separately */
let validateMultipleResults: (FastCSV.csvParserStream, array<FastCSV.importerValidation>) => FastCSV.csvParserStream = (
  parser,
  validations,
) =>
  validations
  ->Array.map(validation => validation->fromImporterValidation)
  ->validateMultiple(parser)
