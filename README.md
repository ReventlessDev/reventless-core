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

Or in development, to run a watcher:
```
npm run start
```

If you use Visual Studio Code, use the [reason-vscode](https://marketplace.visualstudio.com/items?itemName=jaredly.reason-vscode) plugin, which auto-builds the project on save by default.
Otherwise, see https://reasonml.github.io/docs/en/editor-plugins.

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



#### Test Example
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

### 5. Deployment
Before running `npm run deploy`, make sure to update the `.env` file. (Copy your Pulumi Access Token from your profile preferences into the `.env` file.)

This command will run 3 Shell-Scripts:
  * `./scripts/pre-deploy.sh`: Move everything in `./node_modules/bs-platform` to a tmp-directory, but the JS-lib
  * `./scripts/pulumi-up.sh`: Read `PULUMI_ACCESS_TOKEN` and `PULUMI_STACK` from the `.env` file and run `pulumi up` to actually deploy (This script will be only executed, if `pre-deploy` exited successfully.)
  * `./scripts/post-deploy.sh`: Move `bs-platform` back into place from tmp-directory.


**NOTE**: The `./scripts/pulumi-up.sh` exports the environment variable `PULUMI_ACCESS_TOKEN` to make it to the Pulumi CLI available. Export another value and set a `#` before the apropriate line inside`.env` to use another token.


## Setup environment for local development of actual project and framework side by side
### Setup the new project
* add a new "deploy key" in [gitlab](https://gitlab.com/atos-austria/reason/reventless/settings/repository/deploy_token/create#js-deploy-tokens)
* add "private repository" with the new deploy-token to the new project: `"reventless": "git+https://USER-TOKEN:PASSWORD-TOKEN@gitlab.com/atos-austria/reason/reventless.git"`
* run `npm install` for the new project

### Setup the framework project to use the local version in the new version
* clone the framework repo into a local directory
* run `npm link` inside the framework's directory
* run `npm link reventless` inside the new project's directory

## Go back to using the actual framwork-repo as dependency
### Unlink
[Medium Post](https://medium.com/@alexishevia/the-magic-behind-npm-link-d94dcb3a81af)

* run `npm unlink --no-save reventless` in the new project's directory
* run `npm unlink` in the framework's directory

### Alternative
[Medium Post](https://medium.com/dailyjs/how-to-use-npm-link-7375b6219557)

* run `npm uninstall --no-save reventless && npm install` inside the new project's directory
* OPTIONAL: to delete the global symlink of the framework run `npm uninstall` inside the framework's directory

## Ressources
* [Project Wiki](https://gitlab.com/atos-austria/reason/reventless/wikis/home)
