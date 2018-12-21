# Reventless
Reventless is a toolkit for event-sourced CQRS applications on serverless infrastructure written in ReasonML.

It's based on the following technologies:

* [Serverless](https://serverless.com)
* [ReasonML](https://reasonml.github.io/)
* Event-Sourced
* CQRS

## Getting started
### 1. Install BuckleScript (which comes bundled with reason)
[Reason Docs](https://reasonml.github.io/docs/en/installation)
```
npm install -g bs-platform
```

### 2. Install Dependencies
```
npm install
```

### 3. Build Project
```
npm run build
```

Or in development:
```
npm run start
```

If you use Visual Studio Code, use the [reason-vscode](https://marketplace.visualstudio.com/items?itemName=jaredly.reason-vscode) plugin, which auto-builds the project on save by default.

### 4. Test Project
Run Test-Suite once:
```
npm run test
```

Run Test-Suite continously on file changes:
```
npm run dev
```

The Bucklescript bindings for [Jest](https://jestjs.io/) are used as dev-dependency: [bs-jest](https://github.com/glennsl/bs-jest)

### Test example
This tests the function f in the file/module Try:
```
// __tests__/try_test.re
open Jest

describe("Try should return...", () => {
    open Expect
    test("the same text given a count of 0", () => {
        expect(Try.f("test", 0)) |> toBe("test")
    })

    test("the text doubled given a count of 1", () => {
        expect(Try.f("test", 1)) |> toBe("testtest")
    })
})
```
File Try:
```
// src/Try.re
let rec f = (text: string, count: int) => {
    if(count <= 0) text
    else f(text ++ text, count - 1)
}
```


## Ressources
* [Project Wiki](https://gitlab.com/atos-austria/reason/reventless/wikis/home)
