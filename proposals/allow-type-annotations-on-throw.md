# Allow Type Annotation on Throws

* Proposal: [SE-NNNN](#)
* Author(s): [David Owens II](https://github.com/owensd) (https://github.com/owensd)
* Status: **Pending Approval for Review**
* Review manager: TBD

## Introduction
The error handling system within Swift today creates an implicitly loose contract on the API. While this can be desirable in some cases, it’s certainly not desired in _all_ cases. This proposal looks at modifying how the error handling mechanism works today by adding the ability to provide a strong API contract.

## Error Handling State of the Union
This document will use the terminology and the premises defined in the [Error Handling Rationale](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst "Error Handling Rationale") document.

To very briefly summarize, there are four basic classification of errors:

1. Simple Domain Errors
2. Recoverable Errors
3. Universal Errors
4. Logic Failures

Each of these types of errors are handled differently at the call sites. Today, only the first two are directly handled by Swift error handling mechanism. The second two are uncatchable in Swift (such as `fatalError()`, ObjC exceptions, and force-unwrapping of `null` optionals).

### Simple Domain Errors
As stated in [Error Handling Rationale](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst "Error Handling Rationale") document, the “Swift way” to handle such errors is to return an `Optional<T>`.

	func parseInt(value: String) -> Int? {}

The simple fact of the result being `Optional.None` signifies that the string could not be parsed and converted into an `Int`. No other information is necessary or warranted.

### Recoverable Errors
In this context, these are errors that need to provide additional information to the caller. The caller can then decide a course of action that needs to be taken. This could be any number of things, including, but not limited to, logging error information, attempting a retry, or potentially invoking a different code path. All of these errors implement the `ErrorType` protocol.

	func openFile(filename: String) throws {}

The `throws` keyword annotates that the function can return additional error information. The caller must also explicitly make use of this when invoking the function.

	do {
	  try openFile("path/to/somewhere")
	}
	catch {}

Errors are able to propagate if called within another context that can throw, thus alleviating the annoying “catch and rethrow” behavior:

	func parent() throws {
	  try openFile("path/to/somwhere")
	}

Lastly, functions can be marked to selectively throw errors if they take a function parameter that throws with the `rethrows` keyword. The really interesting part is that it’s only necessary to use `try` when calling the function with a throwing closure.

	func openFile(filename: String) throws {}
	func say(message: String) {}
	
	func sample(fn: (_: String) throws -> ()) rethrows {
	    try fn("hi")
	}
	
	try sample(openFile)
	sample(say)

#### Converting Recoverable Errors to Domain Errors
Swift also has the `try?` construct. The notable thing about this construct is that it allows the caller to turn a “Recoverable Error” into a “Simple Domain Error”.

	if let result = try? openFile("") {}

### `ErrorType` Implementors
Errors are implemented using the `ErrorType` protocol. Since it is a protocol, new error types can be a class, a struct, or an enum. A type qualified `throws` clause would allow code authors to change the way that the catch-clauses need to be structured.

#### Enum Based `ErrorType`
When enums are used as the throwing mechanism, a generic catch-clause is still required as the compiler doesn’t have enough information. This leads to ambiguous code paths.

	enum Errors: ErrorType {
	    case OffBy1
	    case MutatedValue
	}
	
	func f() throws { throw Errors.OffBy1 }
	
	do {
	    try f()
	}
	catch Errors.OffBy1 { print("increment by 1") }
	catch Errors.MutatedValue { fatalError("data corrupted") }

The above code requires a `catch {}` clause, but it’s ambiguous what that case should do. There is no _right_ way to handle this error. If the error is ignored, we’re now in the land of “Logic Errors”; the code path should never be hit. If we use a `fatalError()` construct, then we are now in the land of converting a potential compiler error into a “Universal Error”.

Both of these are undesirable.

#### Struct and Class Based `ErrorType`
In the current design, errors that are thrown require a catch-all all the time. In the proposed design, which will be explained further, a catch-all would not be required if there was a case-clause that matched the base type.

	class ErrorOne: ErrorType {}
	func g() throws { throw ErrorOne() }
	
	do {
	    try g()
	}
	catch is ErrorOne { print("ErrorOne") }

The advantage in these cases are different, these cases do not allow pattern matching over the error type members (as you can in a switch-statement, for example).

The workaround for this functionality is this:

	class ErrorOne: ErrorType {
	    let value: Int
	    init(_ value: Int) { self.value = value }
	}
	
	do {
	    try g()
	}
	catch {
	    if let e = error as? ErrorOne {
	        switch e {
	        case _ where e.value == 0: print("0")
	        case _ where e.value == 1: print("1")
	        default: print("nothing")
	        }
	    }
	}

This proposal would turn the above into:

	class ErrorOne: ErrorType {
	    let value: Int
	    init(_ value: Int) { self.value = value }
	}
	
	do {
	    try g()
	}
	catch _ where error.value == 0 { print("0") }
	catch _ where error.value == 1 { print("1") }
	catch { print("nothing") }
	}

No gymnastics to go through, just straight-forward pattern-matching like you’d expect.

NOTE: This requires the promotion of the `error` constant to be allowed through the entirety of the catch-clauses.

#### Overriding
In the context of types, it’s completely possible to override functions with the `throws` annotations. The rules simply follow the rules today: covariance on the return type is allowed, contravariance is not.

#### Generics
When looking at generics, I cannot come up with a reason why they shouldn’t just work as normal:

	func gen<SomeError: ErrorType>() throws SomeError {}

The only constraint would be that the specified error type must adhere to the `ErrorType` protocol. However, this is no different than today:

	func f<T>(a: T) throws { throw a }

This results in the compiler error:
> Thrown expression type ’T’ does not conform to ‘ErrorType’

This seems like it should “just work”.

## Design Change Proposal
The design change is simple and straight-forward: allow for the annotation of the type of error that is being returned as an optional restriction. The default value would still be `ErrorType`.

	func specific() throws MyError {}
	func nonspecific() throws {}

There is a secondary result of this proposal: the `error` constant should be promoted to be allowed for use through-out all of the catch-clauses.

### Impact on Existing Code
This is a non-breaking change. All existing constructs work today without change. That said, there are a few places where this change will have an impact on future usage.

#### Function Declarations
When a function has a `throws` clause that is attributed with a type, then that type becomes part of the function signature. This means that these two functions are not considered to be of the same type:

	func one() throws {}
	func two() throws NumberError {}

The function signatures are covariant though, so either `one` or `two` can be assigned to `f` below:

	let f: () throws -> ()

This is completely fine as `NumberError` still implements the `ErrorType` protocol.

However, in this case:

	let g: () throws NumberError -> ()

It would not be valid to assign `one` to `g` as the type signature is more specific.

#### `throws` and `rethrows`
Functions currently have the ability to be marked as `rethrows`. This basically says that if a closure parameter can throw, then the function will throw too. 

	func whatever(fn: () throws -> ()) rethrows {}

The `whatever` function is up for anything that `fn` is up for. Keeping in line with this mentality, the `rethrows` would exhibit the same behavior: typed annotations simply apply if present and do not if they are missing.

	func specific(fn: () throws HappyError -> ()) rethrows {}

This all works as expected:

	func f() throws HappyError {}
	func g() {}
	
	try specific(f)
	specific(g)

This works for the same covariant reason as the non-qualified `throws` implementation works: a non-throwing function is always able to be passed in for a throwing function.

#### The `do`-`catch` statement
There are two rule changes here, but again, it’s non-breaking.

The first rule change is to promote the `error` constant that would normally only be allowed in the catch-all clause (no patterns) to be available throughout each of the catch clauses. This allows for the error information to be used in pattern matching, which is especially valuable in the non-enum case.

The second change is to allow the `error` constant to take on a specific type when *all* of the throwing functions throw the same specified type. When this is the case, two things become possible:

1. In the enum-type implementation of `ErrorType`, the catch-clauses can now be exhaustive.
2. In the all of the cases, the API of the specific `ErrorType` becomes available in the catch-clause without casting the `error` constant. This greatly simplifies the pattern-matching process.

In the case that there are heterogenous `ErrorType` implementations being returned, the `error` constant simply has the type of `ErrorType`.

#### The `try` call sites
There is no change for the `try`, `try?`, or `try!` uses. The only clarification I’ll add is that `try?` is still the appropriate way to promote an error from a “Recoverable Error” to a “Simple Domain Error”.

## Alternate Proposals
There is another common error handling mechanism used in the community today: `Either<L, R>`. There are various implementations, but they all basically boil down to an enum that captures the value or the error information.

I actually consider my proposal syntactic sugar over this concept. If and when Swift supports covariant generics, there is not a significant reason I can see why the underlying implementation could not just be that.

The advantage is that the proposed (and existing) syntax of `throws` greatly increases the readability and understanding that this function actually possesses the ability to throw errors and they should be handled.

The other advantage of this syntax is that it doesn’t require a new construct to force the usage of the return type. 

Further, if functions where to ever gain the ability to be marked as `async`, this could now be handled naturally within the compiler as the return type could a promise-like implementation for those.

## Criticisms
From the earlier threads on the swift-evolution mailing list, there are a few primary points of contention about this proposal.

##### Aren’t we just creating Java checked-exceptions, which we all know are terrible?
No. The primary reason is that a function can only return a single error-type. This already greatly reduces the deep class-based, exception-type model to a single, polymorphic error type (for class-based `ErrorType` implementations). Swift also takes a different model than Java; this was mostly laid out here: [Error Handling Rationale](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst "Error Handling Rationale"). But briefly, many of the numerous exceptions that are thrown in Java are of the "Universal Error" classification, which Swift's error model doesn't handle.

##### Aren’t we creating fragile APIs that can cause breaking changes?
Potentially, yes. This depends on how the ABI is handled in Swift 3 for enums. The same problem exists today, although at a lesser extent, for any API that returns an enum today.

Chris Lattner mentioned this on the thread:

> The resilience model addresses how the public API from a module can evolve without breaking clients (either at the source level or ABI level).  Notably, we want the ability to be able to add enum cases to something by default, but also to allow API authors to opt into more performance/strictness by saying that a public enum is “fragile” or “closed for evolution”.

So if enums have an attribute that allows API authors to denote the fragility enums, then this can be handled via that route.

Another potential fix is that *only* `internal` and `private` scoped functions are allowed to use the exhaustive-style catch-clauses. For all `public` APIs, they would still need the catch-all clauses.

For APIs that return non-enum based `ErrorType` implementations, then no, this does not contribute to the fragility problem.

##### Aren’t we creating the need for wrapper errors?
This is a philosophical debate. I’ll simply state that I believe that simply re-throwing an error, say some type of IO error, from your API that is not an IO-based API is design flaw: you are exposing implementation details to users. This  creates a fragile API surface.

Also, since the type annotation is opt-in, I feel like this is a really minor argument. If your function is really able to throw errors from various different API calls, then just stick with the default `ErrorType`.

However, it is the case that if you do wish to propogate the errors out, then yes, you need to create wrappers. The Rust language does this today as well.

##### Why are multiple error types not allowed to be specified?
To clear, it's not because of “Java checked exceptions” (as it might be inferred because of the defense to Java's checked exceptions). Rather, it’s because nowhere else in the language are types allowed to be essentially annotated in a sum-like fashion. We can’t directly say a function returns an Int or a String. We can’t say a parameter can take an Int or a Double. Similarly, I propose we can’t say a function can return an error A or B.

Thus, the primary reason is about type-system consistency.

Swift already supports a construct to create sum types: associated enums. What it doesn’t allow is the ability to create them in a syntactic shorthand. In this way, my error proposal does the same thing as Rust: multiple return types need to be combined into a single-type - enum.

If Swift is updated to allow the creation of sum-types and use them as qualifiers for type declarations, then I don't see how they wouldn't simply fall inline here as well.
