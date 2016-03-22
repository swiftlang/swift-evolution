# Add Generic Result and Error Handling to autoreleasepool()

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-autoreleasepool-signature.md)
* Author(s): [Timothy J. Wood](https://github.com/tjw)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

The `autoreleasepool` function in the standard library does not currently
support a return value or error handling, making it difficult and error-prone
to pass results or errors from the body to the calling context.

Swift-evolution thread: A first call for discussion was
[made here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160314/013054.html).
Dmitri Gribenko pointed out that adding a generic return type would be useful
(first in my premature pull request) and then also [here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160321/013059.html).
Jordan Rose [pointed out](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160321/013077.html)
that care was needed to avoid inferring an incorrect return type for the body
block, but after testing we confirmed that this is handled correctly by
the compiler.

## Motivation

The current signature for `autoreleasepool` forces the creation of temporary
variables to capture any results of the inner computation, as well as any error
to eventually throw, in the case they are needed in the calling code. This extra
boilerplate clutters up the intent, as well as introduces the risk of
accidentally unwrapping a `nil` value.

For example:

```swift
func doWork() throws -> Result {
    var result: Result? = nil
    var error: ErrorProtocol? = nil
    autoreleasepool {
        do {
            ... actual computation which hopefully assigns to result but might not ...
        } catch let e {
            error = e
        }
    }
    guard let result = result else {
        throw error!
    }
    return result!
}
```

## Proposed solution

I'd like to propose altering the signature of the standard library
`autoreleasepool` function to allow for a generic return type, as well as
allowing a `throw` of an error:

```swift
public func autoreleasepool<Result>(@noescape body: () throws -> Result) rethrows -> Result
```

The case above becomes much more clear and less error-prone since the compiler
can enforce that exactly one of the error and result are used:

```swift
func doWork() throws -> Result {
    return try autoreleasepool {
        ... actual computation which either returns or throws ...
    }
}
```

As an aside, since this proposes changing the signature already, I would like
to further propose changing the argument label from `code` to `body`. This seems
more in line with the parameter name used in the rest of the standard library,
but isn't central to this proposal.

## Detailed design

The updated standard library function would read:

```swift
public func autoreleasepool<Result>(@noescape body: () throws -> Result) rethrows -> Result {
    let pool = __pushAutoreleasePool()
    defer {
        __popAutoreleasePool(pool)
    }
    return try body()
}
```

## Impact on existing code

No impact expected.

## Alternatives considered

The [original request, SR-842](https://bugs.swift.org/browse/SR-842) only
suggested adding `throws`, but Dmitri Gribenko pointed out that adding a generic
return type would be better.

I also explored whether third-party code could wrap `autoreleasepool` themselves
with something like:

```swift
func autoreleasepool_generic<ResultType>(@noescape code: Void throws -> ResultType) rethrows -> ResultType {
    var result:ResultType?
    var error:ErrorProtocol?

    autoreleasepool {
        do {
            result = try code()
        } catch let e {
            error = e
        }
    }

    if let result = result {
        return result
    }

    throw error! // Doesn't compile.
}
```
  
but this doesn't compile, since in a function with `rethrows`, only the call to
the passed in function that is marked as `throws` is allowed to throw.
Even if it was possible to create a `rethrows` wrapper from the non-throwing
function, it is better to add the safety to the standard library in the
first place.
