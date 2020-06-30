# Add Result to the Standard Library

* Proposal: [SE-0235](0235-add-result.md)
* Author: [Jon Shier](https://github.com/jshier)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 5)**
* Implementation: [apple/swift#21073](https://github.com/apple/swift/pull/21073),
                  [apple/swift#21225](https://github.com/apple/swift/pull/21225),
                  [apple/swift#21378](https://github.com/apple/swift/pull/21378)
* Review: ([initial review](https://forums.swift.org/t/se-0235-add-result-to-the-standard-library/17752)) ([second review](https://forums.swift.org/t/revised-se-0235-add-result-to-the-standard-library/18371)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0235-add-result-to-the-standard-library/18603))

## Introduction

Swift's current error-handling, using `throws`, `try`, and `catch`, offers automatic and synchronous handling of errors through explicit syntax and runtime behavior. However, it lacks the flexibility needed to cover all error propagation and handling in the language. `Result` is a type commonly used for manual propagation and handling of errors in other languages and within the Swift community. Therefore this proposal seeks to add such a type to the Swift standard library.

## Motivation

Swift's [Error Handling Rationale and Proposal](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst) document lays out the reasoning behind and high level details of the current Swift error handling story. Types conforming to `Error` can be propagated and handled using the `do` `try` `catch` `throw` syntax. The rationale document refers to this model as a typed and automatically propagating error system. However, this system has several drawbacks, some of which are mentioned in the rationale document. Namely, it cannot compose with asynchronous work, more complex error handling, or with failure values which don't conform to `Error`. The added flexibility of typed, marked, but manually propagating error type can address these shortcomings. Namely `Result<Value, Error>`.

## Proposed solution

```swift
public enum Result<Success, Failure: Error> {
    case success(Success), failure(Failure)
}
```

`Result<Success, Failure>` is a pragmatic compromise between competing error handling concerns both present and future.

The `Failure` type captured in the `.failure` case is constrained to `Error` to simplify and underline `Result`'s intended use for manually propagating the result of a failable computation.

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
URLSession.shared.dataTask(with: url) { (result: Result<(response: URLResponse, data: Data), Error>) in // Type added for illustration purposes.
    switch result {
    case let .success(success):
        handleResponse(success.response, data: success.data)
    case let .error(error):
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
    switch configuration {
        ...
    }
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
/// A value that represents either a success or a failure, including an
/// associated value in each case.
@_frozen
public enum Result<Success, Failure: Error> {
  /// A success, storing a `Success` value.
  case success(Success)
  
  /// A failure, storing a `Failure` value.
  case failure(Failure)
  
  /// Returns a new result, mapping any success value using the given
  /// transformation.
  ///
  /// Use this method when you need to transform the value of a `Result`
  /// instance when it represents a success. The following example transforms
  /// the integer success value of a result into a string:
  ///
  ///     func getNextInteger() -> Result<Int, Error> { /* ... */ }
  ///
  ///     let integerResult = getNextInteger()
  ///     // integerResult == .success(5)
  ///     let stringResult = integerResult.map({ String($0) })
  ///     // stringResult == .success("5")
  ///
  /// - Parameter transform: A closure that takes the success value of this
  ///   instance.
  /// - Returns: A `Result` instance with the result of evaluating `transform`
  ///   as the new success value if this instance represents a success.
  public func map<NewSuccess>(
    _ transform: (Success) -> NewSuccess
  ) -> Result<NewSuccess, Failure> { }
  
  /// Returns a new result, mapping any failure value using the given
  /// transformation.
  ///
  /// Use this method when you need to transform the value of a `Result`
  /// instance when it represents a failure. The following example transforms
  /// the error value of a result by wrapping it in a custom `Error` type:
  ///
  ///     struct DatedError: Error {
  ///         var error: Error
  ///         var date: Date
  ///
  ///         init(_ error: Error) {
  ///             self.error = error
  ///             self.date = Date()
  ///         }
  ///     }
  ///
  ///     let result: Result<Int, Error> = // ...
  ///     // result == .failure(<error value>)
  ///     let resultWithDatedError = result.mapError({ e in DatedError(e) })
  ///     // result == .failure(DatedError(error: <error value>, date: <date>))
  ///
  /// - Parameter transform: A closure that takes the failure value of the
  ///   instance.
  /// - Returns: A `Result` instance with the result of evaluating `transform`
  ///   as the new failure value if this instance represents a failure.
  public func mapError<NewFailure>(
    _ transform: (Failure) -> NewFailure
  ) -> Result<Success, NewFailure> { }
  
  /// Returns a new result, mapping any success value using the given
  /// transformation and unwrapping the produced result.
  ///
  /// - Parameter transform: A closure that takes the success value of the
  ///   instance.
  /// - Returns: A `Result` instance with the result of evaluating `transform`
  ///   as the new failure value if this instance represents a failure.
  public func flatMap<NewSuccess>(
    _ transform: (Success) -> Result<NewSuccess, Failure>
  ) -> Result<NewSuccess, Failure> { }
  
  /// Returns a new result, mapping any failure value using the given
  /// transformation and unwrapping the produced result.
  ///
  /// - Parameter transform: A closure that takes the failure value of the
  ///   instance.
  /// - Returns: A `Result` instance, either from the closure or the previous 
  ///   `.success`.
  public func flatMapError<NewFailure>(
    _ transform: (Failure) -> Result<Success, NewFailure>
  ) -> Result<Success, NewFailure> { }
  
  /// Returns the success value as a throwing expression.
  ///
  /// Use this method to retrieve the value of this result if it represents a
  /// success, or to catch the value if it represents a failure.
  ///
  ///     let integerResult: Result<Int, Error> = .success(5)
  ///     do {
  ///         let value = try integerResult.get()
  ///         print("The value is \(value).")
  ///     } catch error {
  ///         print("Error retrieving the value: \(error)")
  ///     }
  ///     // Prints "The value is 5."
  ///
  /// - Returns: The success value, if the instance represents a success.
  /// - Throws: The failure value, if the instance represents a failure.
  public func get() throws -> Success { }
}

extension Result where Failure == Swift.Error {
  /// Creates a new result by evaluating a throwing closure, capturing the
  /// returned value as a success, or any thrown error as a failure.
  ///
  /// - Parameter body: A throwing closure to evaluate.
  @_transparent
  public init(catching body: () throws -> Success) { }
}

extension Result: Equatable where Success: Equatable, Failure: Equatable { }

extension Result: Hashable where Success: Hashable, Failure: Hashable { }
```

## Adding `Swift.Error` self-conformance

As part of the preparatory work for this proposal, self-conformance was added for `Error` (and only `Error`). This is also generally useful for working with errors in a generic context.

This self-conformance does not extend to protocol compositions including the `Error` protocol, only the exact type `Error`. It will be possible to add such compositions in the future, but that is out of scope for Swift 5.

## Other Languages
Many other languages have a `Result` type or equivalent:

- Kotlin: [`Result<T>`](https://github.com/Kotlin/KEEP/blob/master/proposals/stdlib/result.md)
- Scala: [`Try[T]`](https://www.scala-lang.org/api/current/scala/util/Try.html) 
- Rust:  [`Result<T, E>`](https://doc.rust-lang.org/std/result/)
- Haskell:  [`Exceptional e t`](https://wiki.haskell.org/Exception)
- C++ (proposed): [`expected<E, T>`](http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2014/n4015.pdf)

## Source compatibility

This is an additive change which could conflict with existing `Result` types, but work done to improve type name shadowing has made it a non-issue.

## Effect on ABI stability

This proposal adds a type to the standard library and so will affect the ABI once added.

## Effect on API resilience

Addition of `Result<Succes, Failure>` should be future proof against additional needs surrounding error handling.

## Alternatives considered

### Alternative Spellings of `Result<Success, Failure>`
A few alternate spellings were proposed:

A previously revised version of this proposal proposed:
```swift
enum Result<Value, Error: Swift.Error> {
    case value(Value)
    case error(Error)
}
```

However, community opposition to this spelling resulted in the current, final spelling. 

Additionally, a hybrid spelling was proposed:

```swift
enum Result<Value, Error> {
    case success(Value)
    case failure(Error)
}
```

This creates an unfortunate asymmetry between the names of the payload types and the names of the cases. This is additional complexity that has to be remembered.

Finally, spellings using `Wrapped` as the success type name were proposed:

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

### Alternatives to `Result<Success, Failure>`

- `Result<T>`: A `Result` without a generic error type fits well with the current error design in Swift. However, it prevents the future addition of typed error handling (typed `throws`).

- `Either<T, U>`: Rather than adopting `Result` directly, basing it on an `Either` type has been considered. However, it's felt that a `Result` type is a more generally useful case of `Either`, and `Either` gives users little in the way of actual API. Also, the two types can exist peacefully alongside each other with little conflict. Additionally, given the relatively unpopularity of the `Either` type in the community (59 apps use the [Either](https://github.com/runkmc/either) CocoaPod) seems to indicate that lacking this type isn't affecting Swift users that much.

### Constraint on the `Error` type

A previous version of this proposal did not constrain the `Failure` type to conform to `Error`. This was largely because adding such a requirement would block `Error` from being used as the `Error` type, since `Error` does not conform to itself. Since we've now figured out how how to make that conformance work, this constraint is unblocked.

Constraining the error type to conform to `Error` is a very low burden, and it has several benefits:

- It simplifies interoperation with error handling by making such operations unconditionally available.

- It encourages better practices for error values, such as using meaningful wrapper types for errors instead of raw `Int`s and `String`s.

- It immediately catches the simple transposition error of writing `Result<Error, Value>`. Programmers coming from functional languages that use `Either` as a `Result` type are especially prone to this mistake: such languages often write the error type as the first argument due to the useful monadic properties of `Either E`.

### Operations

A previous version of this proposal included operations for optionally projecting out the `value` and `error` cases. These operations are useful, but they should be added uniformly for all `enum`s, and `Result` should not commit to providing hard-coded versions that may interfere with future language evolution. In the meantime, it is easy for programmers to add these operations with extensions in their own code.

A previous version of this proposal included a `fold` operation. This operation is essentially an expression-based `switch`, and like the optional case projections, it would be better to provide a general language solution for it than to add a more limited design that covers only a single type.

A previous version of this proposal did not label the closure parameter for the catching initializer. Single-argument unlabeled initializers are conventionally used for conversions, which this is not; usually the closure will be written explicitly, but in case it isn't, a parameter label is appropriate.
