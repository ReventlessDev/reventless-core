/** Setters for an element's inline
    [`style`](https://developer.mozilla.org/docs/Web/API/HTMLElement/style), one per
    property a caller sets, so a misspelt property is a compile error rather than a
    style that silently does nothing. Values are CSS text (`"12px"`, `"none"`).

    {!setProperty} is for a property with no setter here, such as a custom
    property (`--accent`). */
@set @scope("style")
external setWidth: (Dom.element, string) => unit = "width"

@set @scope("style")
external setHeight: (Dom.element, string) => unit = "height"

@set @scope("style")
external setMaxHeight: (Dom.element, string) => unit = "maxHeight"

@set @scope("style")
external setLeft: (Dom.element, string) => unit = "left"

@set @scope("style")
external setTop: (Dom.element, string) => unit = "top"

@set @scope("style")
external setBottom: (Dom.element, string) => unit = "bottom"

@set @scope("style")
external setDisplay: (Dom.element, string) => unit = "display"

@set @scope("style")
external setFlexBasis: (Dom.element, string) => unit = "flexBasis"

@set @scope("style")
external setCursor: (Dom.element, string) => unit = "cursor"

@set @scope("style")
external setUserSelect: (Dom.element, string) => unit = "userSelect"

/** Safari still reads the prefixed form. */
@set @scope("style")
external setWebkitUserSelect: (Dom.element, string) => unit = "webkitUserSelect"

@set @scope("style")
external setTouchAction: (Dom.element, string) => unit = "touchAction"

@send @scope("style")
external setProperty: (Dom.element, string, string) => unit = "setProperty"
