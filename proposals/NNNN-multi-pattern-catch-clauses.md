# Multi-Pattern Catch Clauses

* Proposal: [SE-NNNN](NNNN-multi-pattern-catch-clauses.md)
* Authors: [Owen Voorhees](https://github.com/owenv)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation:
    - [apple/swift#27776](https://github.com/apple/swift/pull/27776)

## Introduction

Currently, each catch clause in a do-catch statement may only contain a single pattern and where clause. This is inconsistent with the behavior of cases in switch statements, which provide similar functionality. It also makes some error handling patterns awkward to express. This proposal extends the grammar of catch clauses to support a comma-separated list of patterns (with optional where clauses), resolving this inconsistency.

Swift-evolution thread: [Thread](https://forums.swift.org/t/multi-pattern-and-conditionally-compiled-catch-clauses/30246)

## Motivation

Currently, Swift only allows up to one pattern and where clause for each catch clause in a do-catch statement, so the following code snippet is not allowed:

```swift
do {
  try performTask()
} catch TaskError.someRecoverableError {    // OK
  recover()
} catch TaskError.someFailure(let msg),
        TaskError.anotherFailure(let msg) { // Not currently valid
  showMessage(msg)
}
```

Because the above snippet is not valid today, developers frequently end up duplicating code between catch clauses, or writing something like the following instead:

```swift
do {
  try performTask()
} catch let error as TaskError {
  switch error {
  case TaskError.someRecoverableError:
    recover()
  case TaskError.someFailure(let msg),
       TaskError.anotherFailure(let msg):
    showMessage(msg)
  default:
    break
  }
}
```

Nesting the switch inside of the catch clause is awkward and defeats the purpose of supporting pattern matching in catch clauses. Splitting the code up into multiple catch clauses requires duplicating the body, which is also undesirable. Supporting a multi-pattern catch clause would allow for code which is both clearer and more concise.

## Proposed solution

Catch clauses should allow the user to specify a comma-separated list of patterns. If an error thrown at runtime in a do block matches any of the patterns in a corresponding catch clause, that catch clause's body should be executed. Similar to switch cases, a user should be able to bind a variable in all patterns of a catch clause and then use it in the body.

With this change, the code snippet from the motivation section is now valid:

```swift
do {
  try performTask()
} catch TaskError.someRecoverableError {    // OK
  recover()
} catch TaskError.someFailure(let msg),
        TaskError.anotherFailure(let msg) { // Also Allowed
  showMessage(msg)
}
```

Now, if `performTask` throws either `TaskError.someFailure("message")` or `TaskError.anotherFailure("message")`, the body of the second catch clause will be executed and `showMessage` will be called.

## Detailed design

### Grammar Changes

The revised catch clause grammar is as follows:

```
catch-clauses -> catch-clause catch-clauses?

catch-clause -> 'catch' catch-item-list? code-block

catch-item-list -> catch-item |
                   catch-item ',' catch-item-list

catch-item -> pattern where-clause? |
              where-clause
```

Note: Expressions with trailing closures are not allowed in any of a catch clause's items to avoid parsing ambiguity. This differs from the behavior of switch cases.

### Semantics

If a catch clause has multiple patterns, then its body will be executed if a thrown error matches any one of those patterns, and has not already matched a pattern from a preceding catch clause. Similar to switch cases, catch clauses with multiple patterns may still contain value bindings. However, those bindings must have the same name and type in each pattern.

## Source compatibility

This proposal maintains source compatibility. It will only result in code compiling which was considered invalid by older compiler versions.

## Effect on ABI stability

This feature has no ABI impact.

## Effect on API resilience

This proposal does not introduce any new features which could become part of a public API.

## Alternatives considered

### Do nothing

This is a relatively minor addition to the language, and arguably would see rather limited usage. However, in the cases where it's needed, it helps the user avoid hard-to-maintain error handling code which either duplicates functionality or nests control flow statements in a confusing manner. This proposal also simplifies Swift's pattern matching model by unifying some of the semantics of switch and do-catch statements.

## Future Directions

There are a number of possible future directions which could increase the expressiveness of catch clauses.

### Implicit `$error` or `error` binding for all catch clauses

Currently, only catch clauses without a pattern have an implicit `error: Error` binding. However, there are some cases where it would be useful to have this binding in all catch clauses to make, for example, re-throwing errors easier. However, using `error` as the identifier for this binding would be a medium-to-large source-breaking change. Instead, we could continue the trend of compiler defined identifiers and use `$error`. `error` in empty catch clauses could then be deprecated and eventually removed in future language versions, a smaller source break.

This change was not included in this proposal because it is source-breaking and orthogonal. If there is interest in this feature, we should probably consider it as an independent improvement which deserves its own proposal.

### `fallthrough` support in catch clauses

Allowing `fallthrough` statements in catch clauses would further unify the semantics of switch cases and catches. However, it is currently undesirable for a number of reasons. First, it would be a source-breaking change for existing do-catch statements which trigger `fallthrough`s in an enclosing switch. Also, there is no historical precedent from other languages for supporting `fallthrough`s in catch statements, unlike switches. Finally, there have not yet been any identified examples of code which would benefit from this functionality.

### Conditional compilation blocks around catch clauses

An earlier draft of this proposal also added support for wrapping catch clauses in conditional compilation blocks, similar to the existing support for switch cases. This was removed in favor of keeping this proposal focused on a single topic, and leaving room for a more comprehensive redesign of conditional compilation in the future, as described in [https://forums.swift.org/t/allow-conditional-inclusion-of-elements-in-array-dictionary-literals/16171](https://forums.swift.org/t/allow-conditional-inclusion-of-elements-in-array-dictionary-literals/16171/29).
