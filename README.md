# Reventless UI

## Core

## Generic Components

This project aims to provide the most commonly types of components in a generic way.

Currently based on [Material-UI](https://material-ui.com/) and [bs-material-ui](https://github.com/jsiebern/bs-material-ui/).

### Concepts

- A _component_ shall do only **one** thing well. (see [Unix Philosphy](https://en.wikipedia.org/wiki/Unix_philosophy#:~:text=The%20Unix%20philosophy%20is%20documented,by%20adding%20new%20%22features%22.))
- For common logic [**Hooks**](https://reactjs.org/docs/hooks-intro.html) shall be used.
- Components should not assume specific types for data to be displayed (only common, shared types)
- Use [Storybook](https://storybook.js.org/) to showcase and test components in isolation.

### What's included in this project?

#### Components

- [x] [Table](#tedtable)
- [x] [FilterBox](#filterbox)
- [x] [JsonSchemaForm](#jsonschemaform)
- [x] [Details](#details)

#### Hooks

- [x] [SortedArrayHook](#sortedarrayhook)
- [x] [PagedArrayHook](#pagedarrayhook)
- [x] [FilteredArrayHook](#filteredarrayhook)

### Usage

- Generate a new Personal Token on GitHub: `Settings > Developer Settings > Personal access tokens > generate new token`
- install `reventless-react` by adding the follwing line to your dependencies in `package.json`:

```json
"reventless-react": "git+https://[INSERT PERSONAL TOKEN HERE]:x-oauth-basic@github.com/Reventless-Universe/reventless-react.git"
```

- add `reventless-react` to your dependencies in `bsconfig.json`
- run `npm install`

### Components

#### Table

A table which is sortable and pagable, displaying an array of records.

##### Usage of Table

```reason
type person = {
  firstName: string,
  lastName: string,
  avatarCredentials: string,
};

let data: array(person) = ...;
let columns =
  Table.(
    [|
      makeColumnDescriptor(
        ~header="First Name"->React.string,
        ~value=person => person.firstName,
        ~render=firstName => React.string(firstName),
        ~compare=Compare.str,
        (),
      ),
      makeColumnDescriptor(
        ~header="Full Name"->React.string,
        ~value=person => (person.firstName, person.lastName),
        ~render=((first, last)) => React.string(first ++ " " ++ last),
        ~compare=((f1, l1), (f2, l2)) => Compare.str(f1 ++ l1, f2 ++ l2),
        (),
      ),
      makeColumnDescriptor(
        ~value=person => person.avatarCredentials,
        ~render=avatar => <MaterialUi_Avatar> avatar </MaterialUi_Avatar>,
        ~header=React.string("Avatar"),
        (),
      ),
      makeColumnDescriptor(
        ~value=person => person.firstName ++ person.lastName,
        ~render=
          id =>
            <button onClick={_ => Js.log2("edit", id)}>
              {React.string("Edit")}
            </button>,
        ~header=React.null,
        (),
      ),
    |]
  );

<Table
      data
      columns
      calculateKey={person => person.firstName ++ person.lastName}
      />
```

#### FilterBox

A box with customizable input fields, which can be used to filter generic data by a set of predicate functions. The `FilterBox` component is ideally used in combination with the `Table` component or any other type of table.

##### Usage of FilterBox

```reason
type person = {
  firstName: string,
  lastName: string,
  age: int,
};

let contains = (base, searchValue) => {
  base
  ->Js.String.toLowerCase
  ->Js.String.includes(searchValue->Js.String.toLowerCase, _);
};

let data: array(person) = ...;

// Initialize the fields the FilterBox should contain, to filter the data. Available fields are "Text", "Int", "Float", "Range", and "Dropdown".
let fields =
  FilterBox.(
    [|
      Text({
        name: "First Name",
        size: `V6,
        defaultValue: "",
        options: (),
        filter: (person, searchValue) =>
          person.firstName->contains(searchValue),
      }),
      Dropdown({
        name: "Last Name",
        size: `V6,
        defaultValue: "",
        options: {
          options: [|"Berger", "Krankl", "Wolf"|],
        },
        filter: (person, searchValue) => person.lastName == searchValue,
      }),
      Range({
        name: "Age",
        size: `V6,
        defaultValue: (0, 100),
        options: {
          min: 0,
          max: 100,
        },
        filter: (person, searchValue) => {
          let (min, max) = searchValue;
          person.age >= min && person.age <= max;
        },
      }),
    |]
  );

let (filteredData, setFilteredData) = React.useState(() => data);

<>
  <FilterBox data fields setFilteredData />
  // For example: The FilterBox can be used in combination with the Table or any other component, as long as a React state is used.
  <Table calculateKey columns=userColumns data=filteredData />
</>;
```

#### JsonSchemaForm

A generic form which can be customized using JSON-Schema. The data as well as the UI are defined in seperate JSON-Schema configurations.

##### Usage of JsonSchemaForm

```reason
let schema = {j|
  {
    "type": "object",
    "title": "Person",
    "properties": {
      "firstName": {
        "title": "First Name",
        "type": "string"
      },
      "lastName": {
        "title": "Last Name",
        "type": "string"
      },
      "age": {
        "title": "Age",
        "type": "number"
      }
    }
  }
|j}->Js.Json.parseExn;

let uiSchema = {j|
  {
    "firstName": {
      "ui:autofocus": true,
      "ui:emptyValue": "",
      "ui:autocomplete": "given-name"
    },
    "lastName": {
      "ui:emptyValue": "",
      "ui:autocomplete": "family-name"
    },
    "age": {
      "ui:widget": "updown"
    }
  }
|j}->Js.Json.parseExn;

<JsonSchemaForm schema uiSchema />
```

#### Details

A generic view to display key,value pairs.

##### Usage of Details

```reason
type data = { name: string, age: int, children: array(string), avatarUrl: string};

let data = {
  name: "Max",
  age: 42,
  children: [| "R2D2", "C3PO" |],
  avatarUrl: "https://pbs.twimg.com/profile_images/747517697034952704/gHvVahDG.jpg"
  };

let header = "Details of " ++ data.name;

let toFields = data => {
    open Details.Field;
    fields()
    ->text("Name", data.name)
    ->text("Age", data.age->Js.Int.toString)
    ->list("Children", data.kids, "No known children")
    ->element("Avatar", <img width="100" src={data.avatarUrl} />)
  };

<Details data toFields header />

```

### Hooks

#### SortedArrayHook

This hook takes an array of any data, an array of comparators, optionally some default values and returns a new sorted array as well as functions to modify the sorting behaviour.

##### Usage of SortedArrayHook

Currently only `sortinSources` of type `Local(...)` get sorted. `Remote(...)` isn't implemented yet.

_Tip: The `Compare` module holds some comperators for the most common types (`string`, `int`, `float`)._

```reason
type person = {
  firstName: string,
  lastName: string,
  age: int,
  country: string,
  avatarCredentials: string,
};

let data: array(person) = ...;
let comparators:
  array(source(('data, 'data) => int, remoteQuery('data))) = [|
  Local((a, b) => Compare.str(b.firstName, a.firstName)),
  Local((a, b) => Compare.str(b.lastName, a.lastName)),
  Local((a, b) => Compare.int(b.age, a.age)),
|];
let defaultSortIndex: int = 0;
let defaultSortDirection: SortedArrayHook.sortDirection = Asc;

let (result, setSortedColumn, sortColumn, sortDirection) =
  SortedArrayHook.use(data, comparators, defaultSortIndex, defaultSortDirection);
```

#### PagedArrayHook

This hook takes an array of any data, optionally some default values and returns a new array containing only a subset of the default data according to the pagination settings used together with functions to modify the pagination and some status data.

##### Usage of PagedArrayHook

```reason
let data: array('a) = ...;
let defaultPage: int = 1;
let defaultRowsPerPage: int = 25;

let (data, setPage, setRowsPerPage, currentPage, rowsPerPage, totalRows) =
    PagedArrayHook.use(
      data,
      defaultPage,
      defaultRowsPerPage,
    );

/* to jump to the next page */
setPage(currentPage+1);

/* to jump to the middle of all records in the current paging options */
setPage(totalRows / rowsPerPage / 2);

/* to display half of all datasets */
setRowsPerPage(totalRows / 2);
```

#### FilteredArrayHook

This hook can be used to filter an array of a generic type by a set of predicate functions.

##### Usage of FilteredArrayHook

```reason
type person = {
  firstName: string,
  lastName: string,
  avatarCredentials: string,
};

let data: array(person) = ...;
let filters = [|
  person => person.firstName == "Jonathan",
  person => person.lastName == "Myers",
  person => person.age <= 100 && person.age >= 0,
|];

let filteredData = FilteredArrayHook.use(data, ~filters);
```
