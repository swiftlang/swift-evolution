# Concurrency in Top-level Code

* Proposal: [SE-NNNN](NNNN-top-level-concurrency.md)
* Authors: [Evan Wilde](https://github.com/etcwilde)
* Review Manager: TBD
* Status: **Awaiting implementation**

*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

Bringing concurrency to top-level code is an expected continuation of the
concurrency work in Swift. This pitch looks to iron out the details of how
concurrency will work in top-level code, specifically focusing on how top-level
variables are protected from data races, and how a top-level code context goes
from a synchronous context to an asynchronous context.

Swift-evolution thread: [Discussion thread topic for concurrency in top-level code](https://forums.swift.org/t/concurrency-in-top-level-code/55001)

## Motivation

The top-level code declaration context works differently than other declaration
spaces. As such, adding concurrency features to this spaces results in questions
that have not yet been addressed.

Variables in top-level code behave as a global-local hybrid variable; they exist
in the global scope and are accessible as global variables within the module,
but are initialized sequentially like local variables. Global variables are
dangerous, especially with concurrency. There are no isolation guarantees made,
and are therefore subject to race conditions.

As top-level code is intended as a safe space for testing out features and
writing pleasant little scripts, this simply will not do.

In addition to the strange and dangerous behavior of variables, changing whether
a context is synchronous or asynchronous has an impact on how function overloads
are resolved, so simply flipping a switch could result in some nasty hidden
semantic changes, potentially breaking scripts that already exist.

## Proposed solution

The solutions will only apply when the top-level code is an asynchronous
context. As a synchronous context, the behavior of top-level code does not
change. In order trigger making the top-level context an asynchronous context, I
propose using the presence of an `await` in one of the top-level expressions.

An await nested within a function declaration or a closure will not trigger the
behavior.

```swift
func doAsyncStuff() async {
  // ...
}

let countCall = 0

let myClosure = {
  await doAsyncStuff() // `await` does not trigger async top-level
  countCall += 1
}

// magicRunAsyncCodeSynchronously<R>(op: () @escaping async throws -> R) rethrows -> R
magicRunAsyncCodeSynchronously(myClosure)


await myClosure() // This `await` will trigger an async top-level
```


Top-level global variables are implicitly assigned a `@MainActor` global actor
isolation to prevent data races. To avoid breaking sources, the variable is
implicitly marked as pre-concurrency up to Swift 6.

```swift
var a = 10

func bar() {
  print(a)
}

bar()
```

After Swift 6, full actor-isolation checking will take place. The usage of `a`
in `bar` will result in an error due to `bar` not being isolated to the
`MainActor`. In Swift 5, this will compile without errors.

## Detailed design

### Asynchronous top-level context detection

The top-level context should be an asynchronous context when one of the
top-level code declarations immediately contains an `await` expression.
Detecting that the `await` is in the immediate context is modelled as an
ASTWalker, walking across each expression and statement.
The walker should not traverse into closure expressions.
A top-level code declaration will not immediately contain a function
declaration, though if one were to exist, the body should be skipped.
An `await` is either detected as an `AwaitExpr`, or as a valid `await` source
location on a `ForEachStmt`.
This behaviour is already described by the `FindInnerAsync` ASTWalker.
Extracting that out and running it across the top-level declarations stored in
the main source file is sufficient for determining whether the top-level code is
an asynchronous context.
A source file contains multiple top-level declarations, if any of them indicate
that they are an asynchronous context with the presence of the `await`, then all
of them are asynchronous contexts.

```swift
var a = 10

Task {
  return await doSomethingAsync(a) // the `await` is not immediately in the
                                   // top-level declaration, and therefore the
                                   // top-level code is not an asynchronous
                                   // context.
}
```

```swift
var a = 10
let t = Task {
  await doSomethingAsync(a)
}

await t.value // `await` is in the immeidate top-level context, therefore the
              // top-level code is an asynchronous context
```

### Variables

Variables in top-level code are initialized sequentially like a local variable,
but are in the global scope and are otherwise treated as global variables.
To prevent data races, variables should implicitly be isolated to the main
actor.
It would be a shame if every top-level variable access had to go through an
`await` though.
Luckily, like the other entrypoints, top-level code runs on the main thread, so
we can make the top-level code space implicitly main-actor isolated so the
variables can be accessed and modified directly.
This is still source-breaking though; a synchronous global function written in
the top-level code will emit an error because the function is not isolated to
the main actor when the variable is.
While the diagnostic is correct in stating that there is a potential data-race,
the source-breaking effect is also unfortunate. To alleviate the source break,
the variable is implicitly annotated with the `@preconcurrency` attribute. The
attribute only applies to Swift 5 code, and once the language mode is updated to
Swift 6, these data races will become hard errors.

In summary, top-level variable declarations behave as though they were declared
with `@MainActor @preconcurrency` in order to strike a nice balance between
data-race safety and reducing source breaks.

Going back to the global behaviour variables, there are some additional design
details that I should point out.

I would like to propose removing the ability to explicitly specify a global
actor on top-level variables. Top-level variables are treated like a hybrid of
global and local variables, which has some nasty consequences. The variables are
declared in the global scope, so they are assumed to be available anywhere. This
results in some nasty memory safety issues, like the following example:

```swift
print(a)
let a = 10
```

The example compiles and prints "0" when executed.
The declaration `a` is available at the `print` statement because it is a global
variable, but it is not yet initialized because initialization happens
sequentially.
Integer types and other primitives are implicitly zero-initialized; however,
classes are referential types, initialized to zero, so this results in a
segmentation fault if the variable is a class type.

Eventually, we would like to plug this hole in the memory model.
The design for that is still in development, but will likely move toward making
top-level variables local variables of the implicit main function.
I am proposing that we disallow explicit global actors to facilitate that change
and reduce the source breakage caused by that change.

## Source compatibility

The `await` expression cannot appear in top-level code today since the top-level
is not an asynchronous context.
As the features proposed herein are enabled by the presence of an `await`
expression in the top level, there are no scripts today that will be affected by
the changes proposed in this proposal.

## Effect on ABI stability

This proposal has no impact on ABI. Functions and variables have the same
signature as before.

## Acknowledgments

Thank you, Doug, for lots of discussion on how to break this down into something
that minimizes source breakage to a level where we can introduce this to Swift
5.
