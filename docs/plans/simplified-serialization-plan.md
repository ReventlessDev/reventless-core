# Simplified Serialization Documentation Plan

## Focus: Essential Features Only

### Simplified Structure (4 main sections)

1. **Introduction** - What is Sury and why we use it
2. **Basic Usage** - `@schema` annotation with essential examples
3. **Common Patterns** - Records, variants, and key annotations (`@as`, `@unboxed`)
4. **Framework Integration** - How Reventless uses Sury schemas

### Essential Examples to Include

#### Basic Types
```rescript
@schema
type userId = string

@schema
type count = int
```

#### Records
```rescript
@schema
type schedule = {
  name: string,
  rate: rate,
  payload: string,
}
```

#### Variants
```rescript
@schema
type effect = Allow | Deny

@schema
type rate = Single(int, int, int, int, int) | Minutes(int) | Hours(int)
```

#### Key Annotations
```rescript
// Custom JSON field names
@schema
type principal = {
  @as("AWS") aws?: string,
  @as("Service") service?: string,
}

// Unboxed variants for cleaner JSON
@schema @unboxed
type actions = | @as("*") AllActions | Action(string)
```

### Framework Integration (Simplified)
- Generated schema functions
- Basic serialization/deserialization usage
- One practical example from the codebase
- mark this chapter as framework internal

### Key Requirements
- **Brevity**: Keep each section concise
- **Practical**: Focus on patterns actually used in the codebase
- **Progressive**: Start simple, build up complexity gradually
- **Actionable**: Developers should be able to use Sury immediately after reading

### Success Criteria
- [ ] Complete replacement of Decco content
- [ ] Cover 80% of common use cases with 20% of the complexity
- [ ] Include 4-5 practical examples from the actual codebase
- [ ] Keep total length under 100 lines
- [ ] Ensure developers can start using Sury immediately

This simplified approach will provide the essential information developers need without overwhelming them with advanced features they may not use immediately.