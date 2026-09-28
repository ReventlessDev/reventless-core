/** A [`NodeList`](https://developer.mozilla.org/docs/Web/API/NodeList), as the array
    ReScript can iterate. `querySelectorAll` answers with one. */
@val
external toArray: Dom.nodeList => array<Dom.element> = "Array.from"
