/** What form fields (`<input>`, `<textarea>`, `<select>`, `<button>`) have beyond
    {!DomElement}: their value and state, and taking focus.

    These read the live property, not the attribute: `value` is what the user has
    typed, where `getAttribute("value")` is still what the page first set. */
@get
external value: Dom.element => string = "value"

@set
external setValue: (Dom.element, string) => unit = "value"

@get
external checked: Dom.element => bool = "checked"

@set
external setChecked: (Dom.element, bool) => unit = "checked"

@set
external setType: (Dom.element, string) => unit = "type"

@set
external setName: (Dom.element, string) => unit = "name"

@set
external setPlaceholder: (Dom.element, string) => unit = "placeholder"

@set
external setReadOnly: (Dom.element, bool) => unit = "readOnly"

@set
external setDisabled: (Dom.element, bool) => unit = "disabled"

@send
external focus: Dom.element => unit = "focus"

/** Selects the field's whole text, so typing replaces it. */
@send
external select: Dom.element => unit = "select"
