# Add Result to the Standard Library

* Proposal: [SE-0235](0235-add-result.md)
* Authors: [Jon Shier](https://github.com/jshier)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Active review (November 28th...December 2nd, 2018)**
* Implementation: [apple/swift#19982](https://github.com/apple/swift/pull/19982)
* Review: ([thread](https://forums.swift.org/t/se-0235-add-result-to-the-standard-library/17752))

## Introduction

Swift's current error-handling, using `throws`, `try`, and `catch`, offers automatic and synchronous handling of errors through explicit syntax and runtime behavior. However, it lacks the flexibility needed to cover all error propagation and handling in the language. `Result` is a type commonly used for manual propagation and handling of errors in other languages and within the Swift community. Therefore this proposal seeks to add such a type to the Swift standard library.

## Motivation

Swift's [Error Handling Rationale and Proposal](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst) document lays out the reasoning behind and high level details of the current Swift error handling story. Types conforming to `Error` can be propagated and handled using the `do` `try` `catch` `throw` syntax. The rationale document refers to this model as a typed and automatically propagating error system. However, this system has several drawbacks, some of which are mentioned in the rationale document. Namely, it cannot compose with asynchronous work, more complex error handling, or with failure values which don't conform to `Error`. The added flexibility of typed, marked, but manually propagating error type can address these shortcomings. Namely `Result<Value, Error>`.

## Proposed solution

```swift
public enum Result<Value, Error: Swift.Error> {
    case value(Value), error(Error)
}
```

`Result<Value, Error>` is a pragmatic compromise between competing error handling concerns both present and future.

The `Error` type captured in the `.error` case is constrained to `Swift.Error` to simplify and underline `Result`'s intended use for manually propagating the result of a failable computation.

### Usage

#### Asynchronous APIs

Most commonly, and seen in abundance when using Apple or Foundation APIs, `Result` can serve to unify the awkwardly disparate parameters seen in asynchronous completion handlers. For instance, `URLSession`'s completion handlers take three optional parameters:

```swift
func dataTask(with url: URL, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask
```

This can make it quite difficult to elegantly consume the results of these APIs:

```swift
URLSession.shared.dataTask(with: url) { (data, response, error) in
    guard error != nil else { self.handleError(error!) }
    
    guard let data = data, let response = response else { return // Impossible? }
    
    handleResponse(response, data: data)
}
```

While this code is only a few lines long, it exposes Swift's complete lack of automatic error handling for asynchronous APIs. Not only was the `error` forcibly unwrapped (or perhaps handled using a slightly less elegant `if` statement), but a possibly impossible scenario was created. What happens if `response` or `data` are `nil`? Is it even possible? It shouldn't be, but Swift currently lacks the ability to express this impossibility. Using `Result` for the same scenario allows for much more elegant code:

```swift
URLSession.shared.dataTask(with: url) { (result: Result<(URLResponse, Data), Error>) in // Type added for illustration purposes.
    switch result {
    case .value(let response):
        handleResponse(response.0, data: response.1)
    case .error(let error):
        handleError(error)
    }
}
```

This API expresses exactly the intended result (either an error or data and response, never all or none) and allows them to be handled much more clearly. 

#### More General Usage

More generally, there are several scenarios in which `Result` can make error handling and the surrounding APIs more elegant.

#### Delayed Handling

There may be times where a developer wants to immediately execute a `throw`ing function but otherwise delay handling the error until a later time. Currently, if they wish to preserve the error, they must break the value and error apart, as is typically seen in completion handlers (see above). This is made even more obnoxious if the developer needs to store the results of more than one function.

```swift
// Properties 
var configurationString: String?
var configurationReadError: Error?

do {
    string = try String(contentsOfFile: configuration)
} catch {
    readError = error
}

// Sometime later...

func doSomethingWithConfiguration() {
    guard let configurationString = configurationString else { handle(configurationError!) }
    
    ... 
}

```

This can be made somewhat cleaner by using a `(string: String?, error: Error?)` to store the result, but it would still have the same usage issues as in the asynchronous case. Using a `Result` is the appropriate answer here, especially with the convenience API for creating a result from a `throw`ing function.

```swift
let configuration = Result { try String(contentsOfFile: configuration) }

// Sometime later...

func doSomethingWithConfiguration() {
    ...
}

```

#### Separating Errors

It's occasionally useful to be able to run `throw`able functions in such way as to allow the developer to disambiguate between the sources of the errors, especially if the errors don't contain the information necessary to do so, or the developer doesn't want to implement such a check. For instance, if we needed to disambiguate between the errors possible when reading files:

```swift
do {
    handleOne(try String(contentsOfFile: oneFile))
} catch {
    handleOneError(error)
}

do {
    handleTwo(try String(contentsOfFile: twoFile))
} catch {
    handleTwoError(error)
}

do {
    handleThree(try String(contentsOfFile: threeFile))
} catch {
    handleThreeError(error)
}
```
This case can be expressed much more clearly using `Result`:

```swift
let one = Result { try String(contentsOfFile: oneFile) }
let two = Result { try String(contentsOfFile: twoFile) }
let three = Result { try String(contentsOfFile: threeFile) }

handleOne(one)
handleTwo(two)
handleThree(three)
```
Additional convenience API on `Result` could make many of these cases even more elegant.

## Detailed design

As implemented in the PR (annotations pending):

```swift
/// A value that represents either a success or failure, capturing associated
/// values in both cases.
@_frozen
public enum Result<Value, Error: Swift.Error> {
  /// A normal result, storing a `Value`.
  case value(Value)
  
  /// An error result, storing an `Error`.
  case error(Error)
  
  /// Evaluates the given transform closure when this `Result` instance is
  /// `.success`, passing the value as a parameter.
  ///
  /// Use the `map` method with a closure that returns a non-`Result` value.
  ///
  /// - Parameter transform: A closure that takes the successful value of the
  ///   instance.
  /// - Returns: A new `Result` instance with the result of the transform, if
  ///   it was applied.
  public func map<NewValue>(
    _ transform: (Value) -> NewValue
  ) -> Result<NewValue, Error>
  
  /// Evaluates the given transform closure when this `Result` instance is
  /// `.failure`, passing the error as a parameter.
  ///
  /// Use the `mapError` method with a closure that returns a non-`Result`
  /// value.
  ///
  /// - Parameter transform: A closure that takes the failure value of the
  ///   instance.
  /// - Returns: A new `Result` instance with the result of the transform, if
  ///   it was applied.
  public func mapError<NewError>(
    _ transform: (Error) -> NewError
  ) -> Result<Value, NewError>
  
  /// Evaluates the given transform closure when this `Result` instance is
  /// `.success`, passing the value as a parameter and flattening the result.
  ///
  /// - Parameter transform: A closure that takes the successful value of the
  ///   instance.
  /// - Returns: A new `Result` instance, either from the transform or from
  ///   the previous error value.
  public func flatMap<NewValue>(
    _ transform: (Value) -> Result<NewValue, Error>
  ) -> Result<NewValue, Error>
  
  /// Evaluates the given transform closure when this `Result` instance is
  /// `.failure`, passing the error as a parameter and flattening the result.
  ///
  /// - Parameter transform: A closure that takes the error value of the
  ///   instance.
  /// - Returns: A new `Result` instance, either from the transform or from
  ///   the previous success value.
  public func flatMapError<NewError>(
    _ transform: (Error) -> Result<Value, NewError>
  ) -> Result<Value, NewError>

  /// Unwraps the `Result` into a throwing expression.
  ///
  /// - Returns: The success value, if the instance is a success.
  /// - Throws:  The error value, if the instance is a failure.
  public func unwrapped() throws -> Value
}

extension Result where Error == Swift.Error {
  /// Create an instance by capturing the output of a throwing closure.
  ///
  /// - Parameter throwing: A throwing closure to evaluate.
  @_transparent
  public init(catching body: () throws -> Value)
}

extension Result : Equatable where Value : Equatable, Error : Equatable { }

extension Result : Hashable where Value : Hashable, Error : Hashable { }

extension Result : CustomDebugStringConvertible { }
```

## `Swift.Error` self-conformance

In order for this design to be practical, Swift's `Error` must be made to "self-conform" so that it can be used as the second type argument.  That change has been implemented and is now part of this proposal.

## Other Languages
Many other languages have a `Result` type or equivalent:

- Kotlin: [`Result<T>`](https://github.com/Kotlin/KEEP/blob/master/proposals/stdlib/result.md)
- Scala: [`Try[T]`](https://www.scala-lang.org/api/current/scala/util/Try.html) 
- Rust:  [`Result<T, E>`](https://doc.rust-lang.org/std/result/)
- Haskell:  [`Exceptional e t`](https://wiki.haskell.org/Exception)
- C++ (proposed): [`expected<E, T>`](http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2014/n4015.pdf)

## Source compatibility

This is an additive change, but could conflict with `Result` types already defined.

## Effect on ABI stability

This proposal adds a type to the standard library and so will affect the ABI once added.

## Effect on API resilience

Addition of `Result<Value, Error>` should be future proof against future needs surrounding error handling.

## Alternatives considered

### Alternative Spellings of `Result<Value, Error>`
A few alternate spellings were proposed:

```swift
enum Result<Value, Error> {
    case success(Value)
    case failure(Error)
}
```

This creates an unfortunate asymmetry between the names of the payload types and the names of the cases.  This is just additional complexity that has to be remembered.  It's true that these case names don't align with some of the most common community implementations of the `Result` type, meaning that adoption of `Result` will require additional source changes for clients of those projects.  However, this cannot be an overriding concern.

```swift
enum Result<Wrapped, Failure> {
    case value(Wrapped)
    case error(Failure)
}
```
```swift
enum Result<Wrapped, Failure> {
    case some(Wrapped)
    case error(Failure)
}
```

The use of `Wrapped` in these spellings emphasizes more of a similarity to `Optional` than seems appropriate.

### Alternatives to `Result<Value, Error>`

- `Result<T>`: A `Result` without a generic error type fits well with the current error design in Swift. However, it prevents the future addition of typed error handling (typed `throws`).

- `Either<T, U>`: Rather than adopting `Result` directly, basing it on an `Either` type has been considered. However, it's felt that a `Result` type is a more generally useful case of `Either`, and `Either` gives users little in the way of actual API. Also, the two types can exist peacefully alongside each other with little conflict. Additionally, given the relatively unpopularity of the `Either` type in the community (59 apps use the [Either](https://github.com/runkmc/either) CocoaPod) seems to indicate that lacking this type isn't affecting Swift users that much.

### Constraint on the `Error` type

A previous version of this proposal did not constrain the `Error` type to conform to `Swift.Error`.  This was largely due to technical limitations which will be lifted as part of this proposal.

Constraining the error type to conform to `Error` is a very low burden, and it has several benefits:

- It simplifies interoperation with error handling by making such operations unconditionally available.

- It encourages better practices for error values, such as using meaningful wrapper types for errors instead of raw `Int`s and `String`s.

- It immediately catches the simple transposition error of writing `Result<Error, Value>`.  Programmers coming from functional languages that use `Either` as a `Result` type are especially prone to this mistake: such languages often write the error type as the first argument due to the useful monadic properties of `Either E`.

### Operations

A previous verson of this proposal included operations for optionally projecting out the `value` and `error` cases.  These operations are useful, but they should be added uniformly for all `enum`s, and `Result` should not commit to providing hard-coded versions that may interfere with future language evolution.  In the meantime, it is easy for programmers to add these operations with extensions in their own code.

A previous version of this proposal included a `fold` operation.  This operation is essentially an expression-based `switch`, and like the optional case projections, it would be better to provide a general language solution for it than to add a more limited design that covers only a single type.

A previous version of this proposal did not label the closure parameter for the catching initializer.  Single-argument unlabeled initializers are conventionally used for conversions, which this is not; usually the closure will be written explicitly, but in case it isn't, a parameter label is appropriate.

There are several different names that would be reasonable for the `unwrapped` operation, such as `get`.  None of these names seem obviously better than `unwrapped`.
