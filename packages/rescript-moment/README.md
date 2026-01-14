# rescript-moment

[![CI](https://github.com/Jimexist/bs-moment/actions/workflows/ci.yml/badge.svg)](https://github.com/Jimexist/bs-moment/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/bs-moment.svg)](https://www.npmjs.com/package/bs-moment)

ReScript bindings for [Moment.js](https://momentjs.com/).

## Installation

```bash
npm install @reventless/rescript-moment moment
```

Add to your `rescript.json`:

```json
{
  "bs-dependencies": [
    "@reventless/rescript-moment"
  ]
}
```

## Usage

Import the module in your ReScript code:

```rescript
open MomentRe
```

### Creating Moments

```rescript
// Current time
let now = momentNow()

// From string
let date = moment("2024-01-15")

// From string with format
let dateWithFormat = moment(~format=["DD-MM-YYYY"], "15-01-2024")

// From JavaScript Date
let fromDate = momentWithDate(Js.Date.make())

// From Unix timestamp (seconds)
let fromUnix = momentWithUnix(1705276800)

// From milliseconds timestamp
let fromMillis = momentWithTimestampMS(1705276800000.0)

// UTC
let utcDate = momentUtc("2024-01-15T10:30:00Z")
```

### Formatting and Display

```rescript
let m = moment("2024-01-15")

// Format with pattern
let formatted = m->Moment.format("YYYY-MM-DD") // "2024-01-15"
let custom = m->Moment.format("MMMM Do YYYY") // "January 15th 2024"

// Default format
let default = m->Moment.defaultFormat

// Relative time
let relative = m->Moment.fromNow(~withoutSuffix=None) // "3 days ago"

// To JavaScript Date
let jsDate = m->Moment.toDate

// To Unix timestamp (seconds)
let unix = m->Moment.toUnix

// To ISO string
let iso = m->Moment.toISOString()
```

### Getting Values

```rescript
let m = moment("2024-01-15 14:30:45")

let year = m->Moment.year        // 2024
let month = m->Moment.month      // 0 (January)
let date = m->Moment.date        // 15
let hour = m->Moment.hour        // 14
let minute = m->Moment.minute    // 30
let second = m->Moment.second    // 45

// Generic getter with polymorphic variant
let day = m->Moment.get(#day)
```

### Mutable vs Immutable Operations

This binding takes an **opinionated approach** to mutations. Methods that mutate the moment object in JavaScript are prefixed with `mutable` in ReScript. Immutable versions (without prefix) automatically clone the moment first.

#### Immutable Operations (Recommended)

These return a **new** moment without modifying the original:

```rescript
let original = moment("2024-01-15")

// Adding time - returns new moment
let future = original->Moment.add(~duration=duration(3., #days))

// Subtracting time - returns new moment
let past = original->Moment.subtract(~duration=duration(1., #months))

// Setting values - returns new moment
let updated = original
  ->Moment.setYear(2025)
  ->Moment.setMonth(5)
  ->Moment.setDate(20)

// Start/end of time periods - returns new moment
let startOfDay = original->Moment.startOf(#day)
let endOfMonth = original->Moment.endOf(#month)

// Original is unchanged
let stillSame = original->Moment.format("YYYY-MM-DD") // "2024-01-15"
```

#### Mutable Operations (Use with Caution)

These **modify** the moment object in place and return `unit`:

```rescript
let m = moment("2024-01-15")

// Modifies m directly - returns unit
m->Moment.mutableAdd(duration(3., #days))
m->Moment.mutableSetYear(2025)
m->Moment.mutableStartOf(#week)

// m has been modified
let modified = m->Moment.format("YYYY-MM-DD")
```

⚠️ **Best Practice:** Use immutable operations to avoid unexpected mutations in your code.

### Durations

```rescript
// Create durations with polymorphic variants
let threeDays = duration(3., #days)
let twoHours = duration(2., #hours)
let fiveMinutes = duration(5., #minutes)

// From milliseconds
let millis = durationMillis(86400000.0)

// From ISO 8601 format
let isoDuration = durationFormat("P2D") // 2 days

// Duration operations
let d = duration(2.5, #hours)

d->Duration.hours       // 2
d->Duration.minutes     // 30
d->Duration.asHours     // 2.5
d->Duration.asMinutes   // 150.0
d->Duration.humanize    // "3 hours"
d->Duration.toISOString // "PT2H30M"

// Use with moment
let m = moment("2024-01-15")
let future = m->Moment.add(~duration=duration(1., #weeks))
```

### Comparisons

```rescript
let date1 = moment("2024-01-15")
let date2 = moment("2024-01-20")

// Basic comparisons
date1->Moment.isBefore(date2)          // true
date1->Moment.isAfter(date2)           // false
date1->Moment.isSame(date2)            // false
date1->Moment.isSameOrBefore(date2)    // true

// With granularity
Moment.isSameWithGranularity(date1, date2, #month)  // true
Moment.isSameWithGranularity(date1, date2, #day)    // false

// Is between
let middle = moment("2024-01-17")
Moment.isBetween(middle, date1, date2) // true

// Validation
date1->Moment.isValid    // true
date1->Moment.isLeapYear // true (2024 is a leap year)
```

### Differences

```rescript
let start = moment("2024-01-15")
let end = moment("2024-01-20")

// Calculate differences with polymorphic variants
let daysDiff = diff(end, start, #days)        // 5.0
let hoursDiff = diff(end, start, #hours)      // 120.0
let monthsDiff = diff(end, start, #months)    // 0.16...

// With precision
let preciseDiff = diffWithPrecision(end, start, #months, true)
```

### Time Units (Polymorphic Variants)

The bindings use ReScript's polymorphic variants for type-safe time unit selection:

```rescript
#milliseconds | #seconds | #minutes | #hours | #days |
#weeks | #months | #quarters | #years

#millisecond | #second | #minute | #hour | #day |
#week | #month | #quarter | #year | #isoWeek
```

## Status

This package is stable and maintained. New bindings are added as needed. Feel free to create an issue or PR if you find anything missing.

## Deprecations

Deprecated Moment.js methods (e.g. `moment().days` in favor of `moment().day`) are not included in this binding.
