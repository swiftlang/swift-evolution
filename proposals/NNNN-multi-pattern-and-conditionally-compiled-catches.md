# Multi-Pattern and Conditionally Compiled Catch Clauses

* Proposal: [SE-NNNN](NNNN-multi-pattern-and-conditionally-compiled-catches.md)
* Authors: [Owen Voorhees](https://github.com/owenv)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation:
    - [apple/swift#27776](https://github.com/apple/swift/pull/27776) (multi-pattern catch clauses)
    - [apple/swift#27905](https://github.com/apple/swift/pull/27905) (conditionally compiled catch clauses)

## Introduction

Currently, each catch clause in a do-catch statement may only contain a single pattern and where clause, and may not be conditionally compiled using a `#if` directive. This is inconsistent with the behavior of cases in switch statements which provide similar functionality. It also makes some error handling patterns awkward to express. This proposal extends the grammar of catch clauses to support `#if` and a comma-separated list of patterns (with optional where clauses), resolving this inconsistency.

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
} catch {
  switch error {
  case TaskError.someRecoverableError:
    recover()
  case TaskError.someFailure(let msg),
       TaskError.anotherFailure(let msg):
    showMessage(msg)
  }
}
```

Nesting the switch inside of the catch clause is awkward and defeats the purpose of supporting pattern matching in catch clauses. Splitting the code up into multiple catch clauses requires duplicating the body, which is also undesirable. Supporting a multi-pattern catch clause would allow for code which is both clearer and more concise.

The following use of `#if` is also not allowed today and frequently leads to nesting of switch statements inside catch clauses:

```swift
do {
  try performTask()
}
#if os(macOS)
catch TaskError.macOSOnlyError {
  macOSRecovery()
}
#endif
catch { 
  crossPlatformRecovery()
}
``` 

## Proposed solution

Catch clauses should allow the user to specify a comma-separated list of patterns. If an error thrown at runtime in a do block matches any of the patterns in a corresponding catch clause, that catch clause's body should be executed. Similar to switch cases, a user should be able to bind a variable in all patterns of a catch clause and then use it in the body.

Additionally, conditional compilation directives should be permitted to appear surrounding catch clauses.

When used together, these additions allow writing code like the following:

```swift
do {
  try performTask()
} 
#if os(macOS)
catch TaskError.macOSOnlyError {            // A conditionally compiled catch clause
  macOSRecovery()
}
#endif
catch TaskError.someOtherFailure(let msg),  // Multiple patterns in a single catch clause
      TaskError.anotherFailure(let msg) {
  showMessage(msg)
}
```

## Detailed design

### Grammar Changes

The revised catch clause grammar is as follows:

```
catch-clauses -> catch-clause catch-clauses?

catch-clause -> 'catch' catch-item-list? code-block |
                conditional-catch-clause

catch-item-list -> catch-item |
                   catch-item ',' catch-item-list

catch-item -> pattern where-clause? |
              where-clause

conditional-catch-clause -> catch-if-directive-clause catch-elseif-directive-clauses? catch-else-directive-clause? endif-directive

catch-if-directive-clause -> if-directive compilation-condition catch-clauses?

catch-elseif-directive-clauses -> catch-elseif-directive-clause catch-elseif-directive-clauses?

catch-elseif-directive-clause -> elseif-directive compilation-condition catch-clauses?

catch-else-directive-clause -> else-directive catch-clauses?
```

Note: Where clause expressions with trailing closures are not allowed in any of a catch clause's patterns. This differs from the behavior of switch cases.

### Semantics

If a catch clause has multiple patterns, then its body will be executed if a thrown error matches any one of those patterns, and has not already matched a pattern from a preceding catch clause. Similar to switch cases, catch clauses with multiple patterns may still contain value bindings. However, those bindings must have the same name and type in each pattern.

Catch clauses within conditional compilation blocks work just like any other supported construct. The clause must parse whether or not the provided condition evaluates to true, so long as it does not include a compiler version condition. If the condition does not evaluate to true, the compiler will not consider it beyond the parsing stage.

## Source compatibility

This proposal maintains source compatibility. It will only result in code compiling which was considered invalid by older compiler versions.

## Effect on ABI stability

This feature has no ABI impact.

## Effect on API resilience

This proposal does not introduce any new features which could become part of a public API.

## Alternatives considered

### Do nothing

These features are relatively minor additions to the language, and arguably would see rather limited usage. However, in the cases where they are needed, they help the user avoid hard-to-maintain error handling code which either duplicates functionality or nests control flow statements in a confusing manner. This proposal also simplifies Swift's pattern matching and conditional compilation models by unifying some of the semantics of switch and do-catch statements.

## Future Directions

There are a number of possible future directions which could increase the expressiveness of catch clauses.

### Implicit `$error` or `error` binding for all catch clauses

Currently, only catch clauses without a pattern have an implicit `error: Error` binding. However, there are some cases where it would be useful to have this binding in all catch clauses to make, for example, re-throwing errors easier. However, using `error` as the identifier for this binding would be a medium-to-large source-breaking change. Instead, we could continue the trend of compiler defined identifiers and use `$error`. `error` in empty catch clauses could then be deprecated and eventually removed in future language versions, a smaller source break.

This change was not included in this proposal because it is source-breaking and orthogonal. If there is interest in this feature, we should probably consider it as an independent improvement which deserves its own proposal.

### `fallthrough` support in catch clauses

Allowing `fallthrough` statements in catch clauses would further unify the semantics of switch cases and catches. However, it is currently undesirable for a number of reasons. First, it would be a source-breaking change for existing do-catch statements which trigger `fallthrough`s in an enclosing switch. Also, there is no historical precedent from other languages for supporting `fallthrough`s in catch statements, unlike switches. Finally, there have not yet been any identified examples of code which would benefit from this functionality.
