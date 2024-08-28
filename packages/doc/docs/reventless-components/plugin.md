---
title: Plugin
date: 2021-11-22
draft: true
---

TODO

```
- Should we place extension and extensionPoint sections here instead?
- Links and highlighting
- Diagram?
```

The plugin component serves as the [bounded context](https://martinfowler.com/bliki/BoundedContext.html) in a reventless application. Usually for each domain, a bounded context will establish a clear boundary both regarding naming and functionality. Plugins do the same by grouping aggregates to represent a set of functions required for each part of a reventless application. Aggregates must reside inside a Plugin and cannot exist on their own. Aggregates inside a plugin can communicate with each other directly, while aggregates residing in a different plugin communicate via an Extension or ExtensionPoint. Both the Extension and ExtensionPoint serve as a translation layer between plugins. More detailed information on the Extension and ExtensionPoint can be found in their respective page in the documentation.

TODO: Example Plugin
