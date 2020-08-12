[@decco]
type id = Id.String.t;
type name = string;

module type T = {
  [@decco]
  type command;
  [@decco]
  type event;

  let name: name;
};
