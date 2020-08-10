[@decco]
type id = string;
type name = string;

module type T = {
  [@decco]
  type command;
  [@decco]
  type event;

  let name: name;
};
