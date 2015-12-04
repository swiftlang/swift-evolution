# Allow Type Annotation on Throws

* Proposal: [SE-NNNN](#)
* Author(s): [David Owens II](Da)(https://github.com/owensd)
* Status: **Review**
* Review manager: TBD

## Introduction

One of the strengths of Swift is its pursuit of type-safeness. After all, one of Swift’s primary goals is “to make writing and maintaining *correct* programs easier for the developer.”[^1] The current implementation of `throws` makes this challenging. 

## Proposed solution

The proposed solution is to allow type annotation on the `throws` clause:

	func someFunc() throws SomeErrorType -> () {}

This provides the compiler with the ability to provide the following benefit to developers:

1. Assurance that the function can only `throw` an error of the specified type.
2. Assurance that the caller of the function has no ambiguous error states that can happen with later changes to the codebase, verifiable at compile-time instead of run-time.

In the absence of a type qualifier, the function error type would simply be considered an implementation of `ErrorType`.

This recommendation is only to allow a single error type to be returned. Allowing multiple return types could be more confusing and would complicate the implementation. If a developer really needed to return multiple different types of errors, they could create a new enum that encapsulated both of those. Optionally, the compiler could do this implicitly.

> Note: This recommendation really only significantly improves the experience when working with `ErrorType` implementations that are enums. `NSError` bridged errors and other Swift-types would continue to have a deficiency here. At best, I think a pattern-matched case statement for the specific type annotated is the extent to which that experience would be improved, which is still arguably better.
> 
> Another alternative would be to force `ErrorType` protocols to be implementable only by an `enum`, but that is out-of-scope for this proposal.

## Impact on existing code

This should be a non-breaking change for existing code as it is an additive, optional type qualifier.

## Alternatives considered

Another popular error mechanism is through the use of `Error<ErrorType>` and `Result<ResultType, ErrorType>` return values. There are some advantages to this, especially in the context of some async styles of coding. However, with the above `throws` recommendation, it keeps in-tact the compiler’s ability to turn a `throws` construct into one of the aforementioned constructs.

[^1]:	[https://swift.org/about/](https://swift.org/about/)