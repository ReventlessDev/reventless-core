@@reventless.projection

let project = ({event}) =>
  switch event {
  | RegistrationOpened({role, ?until}) => [Set(role, {role, isOpen: true, until})]
  | RegistrationClosed({role}) => [Set(role, {role, isOpen: false, until: None})]
  }
