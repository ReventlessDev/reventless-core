# Reventless
Reventless is a toolkit for event-sourced CQRS applications on serverless infrastructure written in ReasonML.

It's based on the following technologies:

* [Serverless](https://serverless.com)
* [ReasonML](https://reasonml.github.io/) using [Bucklescript](https://bucklescript.github.io/)
* Event-Sourced
* CQRS

## Getting started developing Reventless
### 1. Install Node 12.x (LTS)
We use `fnm` to manage the locally installed node-version.  
The currently used/tested node version is stated in the `.node-version` file.

#### [fnm](https://github.com/Schniz/fnm)
> Fast and simple Node.js version manager, built in native ReasonML

*Note: Currently this tool has no windows-support and is unlikely to be added in the near future.*

Go to your reventless-directory and execute [`fnm use`](https://github.com/Schniz/fnm#fnm-use-version) in a shell to just set you node version to the one stated in `.node-version`. (maybe you want to set your default node version by calling [`fnm default <version>`](https://github.com/Schniz/fnm#fnm-default-version))

### 2. Install BuckleScript (which comes bundled with reason)
Currently used and supported version is bs-platform 5.2.1.

[Reason Docs](https://reasonml.github.io/docs/en/installation)  
[Unofficial Community Docs](https://reasonml.org/docs/manual/latest/installation)

The docs suggest to globally install `bs-platform` (by running `npm install -g bs-platform`), but to avoid version-conflicts it's better to just locally install `bs-platform` when needed or run `npx`. Run the following command to install `bs-platform` locally without adding it to `package.json`:
```
npm install bs-platform@5.2.1 --no-save
```

### 3. Install Dependencies
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

*Note: Don't run the watcher and use the editor-plugin at the same time, since they may conflict with each other.*

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
**TODO: This should be moved to a separate chapter on how to use Reventless in a project.**

Before running `npm run deploy`, make sure to update the `.env` file. (Copy your Pulumi Access Token from your profile preferences into the `.env` file.)
You also need to set the environment variable like `export AWS_SDK_LOAD_CONFIG=1` and hava a file at `~/.aws/config`:
```
[default]
region = eu-west-1
output = json
```

This command will run 3 Shell-Scripts:
  * `./scripts/pre-deploy.sh`: Move everything in `./node_modules/bs-platform` to a tmp-directory, but the JS-lib
  * `./scripts/pulumi-up.sh`: Read `PULUMI_ACCESS_TOKEN` and `PULUMI_STACK` from the `.env` file and run `pulumi up` to actually deploy (This script will be only executed, if `pre-deploy` exited successfully.)
  * `./scripts/post-deploy.sh`: Move `bs-platform` back into place from tmp-directory.


**NOTE**: The `./scripts/pulumi-up.sh` exports the environment variable `PULUMI_ACCESS_TOKEN` to make it to the Pulumi CLI available. Export another value and set a `#` before the apropriate line inside`.env` to use another token.


## Setup environment for local development of actual project and framework side by side -- DEPRECATED


**🚨 We encountered some deployment issues, when using npm link. Therefore we discourage using this technic for the time being❗**

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

# Coding Guidelines

* `<Component>.Make.createComponent` (binding to `Component.js` constructor): Pass any additional parameters (besides `componentType`, `name`, `opts`) directly to the `construct` function (using partial application), like this: `createComponent(~componentType, ~name, ~construct=construct(~param1, ~param2), ~opts)`

# Code-Smells

## ReasonML
* `...->ignore`

## Pulumi
* `...->Pulumi.Output.apply(_, ...)`
* `...->Pulumi.Output.all->Pulumi.Output.apply(...)`
