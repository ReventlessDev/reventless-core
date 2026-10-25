// The shop's roles: the one the registration commands require — `Admin`, the
// framework's administrator, who opens and closes registration — and the ones
// an account may be admitted to, as `Admission.res` declares.
type t =
  | Admin
  | Shopper
  | Merchandiser
  | Fulfilment
