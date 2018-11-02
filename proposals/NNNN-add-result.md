# Add Result to the Standard Library

* Proposal: [SE-NNNN](NNNN-add-result.md)
* Authors: [Jon Shier](https://github.com/jshier)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift#19982](https://github.com/apple/swift/pull/19982)

## Introduction

Swift's current error-handling, using `throws`, `try`, and `catch`, offers automatic and synchronous handling of errors through explicit syntax and runtime behavior. However, it lacks the flexibility needed to cover all error propagation and handling in the language. `Result` is a type commonly used for manual propagation and handling of errors in other languages and within the Swift community. Therefore this proposal seeks to add such a type to the Swift standard library.

## Motivation

Swift's [Error Handling Rationale and Proposal](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst) document lays out the reasoning behind and high level details of the current Swift error handling story. Types conforming to `Error` can be propagated and handled using the `do` `try` `catch` `throw` syntax. The rationale document refers to this model as a typed and automatically propagating error system. However, this system has several drawbacks, some of which are mentioned in the rationale document. Namely, it cannot compose with asynchronous work, more complex error handling, or with failure values which don't conform to `Error`. The added flexibility of typed, marked, but manually propagating error type can address these shortcomings. Namely `Result<Value, Error>`.

## Proposed solution

```swift
public enum Result<Value, Error> {
    case success(Value), failure(Error)
}
```

`Result<Value, Error>` is a pragmatic compromise between competing error handling concerns both present and future. It is unconstrained for the `Error` type captured in the `.failure` case both to allow for a possible typed-`throws` future and to allow failures to return values that don't conform to `Swift.Error`.

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
URLSession.shared.dataTask(with: url) { (result: Result<(URLResponse, Data), (Error, URLResponse?)>) in // Type added for illustration purposes.
    switch result {
    case .success(let response):
        handleResponse(response.0, data: response.1)
    case .failure(let error):
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
public enum Result<Value, Error> {
  /// A success, storing a `Value`.
  case success(Value)
  
  /// A failure, storing an `Error`.
  case failure(Error)
  
  /// The stored value of a successful `Result`. `nil` if the `Result` was a
  /// failure.
  public var value: Value? { get }
  
  /// The stored value of a failure `Result`. `nil` if the `Result` was a
  /// success.
  public var error: Error? { get }
  
  /// A Boolean value indicating whether the `Result` as a success.
  public var isSuccess: Bool { get }
  
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
  
  /// Evaluates the given transform closures to create a single output value.
  ///
  /// - Parameters:
  ///   - onSuccess: A closure that transforms the success value.
  ///   - onFailure: A closure that transforms the error value.
  /// - Returns: A single `Output` value.
  public func fold<Output>(
    onSuccess: (Value) -> Output,
    onFailure: (Error) -> Output
  ) -> Output
}

extension Result where Error: Swift.Error {
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
  public init(_ throwing: () throws -> Value)
  
  /// Unwraps the `Result` into a throwing expression.
  ///
  /// - Returns: The success value, if the instance is a success.
  /// - Throws:  The error value, if the instance is a failure.
  public func unwrapped() throws -> Value
  
  /// Evaluates the given transform closure when this `Result` instance is
  /// `.success`, passing the value as a parameter and flattening the result.
  ///
  /// - Parameter transform: A closure that takes the successful value of the
  ///   instance.
  /// - Returns: A new `Result` instance, either from the transform or from
  ///   the previous error value.
  public func flatMap<NewValue>(
    _ transform: (Value) throws -> NewValue
  ) -> Result<NewValue, Error>
}

extension Result : Equatable where Value : Equatable, Error : Equatable { }

extension Result : Hashable where Value : Hashable, Error : Hashable { }

extension Result : CustomDebugStringConvertible { }
```

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
Two alternate spellings were proposed:

```swift
enum Result<Value, Error> {
    case value(Value)
    case error(Error)
}
```
and 

```swift
enum Result<Wrapped, Failure> {
    case value(Value)
    case error(Error)
}
```
However, these spellings emphasize more of a similarity to `Optional` than seems appropriate. Emphasizing `Result` good/bad, yes/no, success/failure nature seems more inline with the typical usage and meaning of the type. Using `success` and `failure` cases makes that usage completely clear. The `Value`/`Error` generic types appropriately convey the usage of the individual types along the same lines. Ultimately, however, the proposed spelling benefits from the fact that's it's the most common spelling implemented by the Swift community, making it the easiest to drop in and replace existing implementations, as well as benefitting from the current level of community knowledge around the type.

### Alternatives to `Result<Value, Error>`

- `Result<T>`: A `Result` without a generic error type fits well with the current error design in Swift. However, it prevents the future addition of typed error handling (typed `throws`), as well as locking all `Result` usage into failure types which conform to `Error`.

- `Result<T, E: Error>`: A `Result` that constrains its error type to just those types conforming to `Error` allows for fully typed error handling. However, this type is incompatible with current Swift error handling, as it cannot capture unconstrained `Error` values. This would require either casting to a specific error type (commonly `NSError`, which is an anti-pattern) or the addition of a `Error` box type, such as `AnyError`. Additionally, the constraint prevents future growth towards capturing non-`Error` conforming types.

- `Either<T, U>`: Rather than adopting `Result` directly, basing it on an `Either` type has been considered. However, it's felt that a `Result` type is a more generally useful case of `Either`, and `Either` gives users little in the way of actual API. Also, the two types can exist peacefully alongside each other with little conflict. Additionally, given the relatively unpopularity of the `Either` type in the community (59 apps use the [Either](https://github.com/runkmc/either) CocoaPod) seems to indicate that lacking this type isn't affecting Swift users that much.
