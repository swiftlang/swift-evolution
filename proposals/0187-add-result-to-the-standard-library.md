# Add Result<T> To The Standard Library

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Jon Shier](https://github.com/jshier)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

Swift's current error-handling, using `throws`, `try`, and `catch`, is considered a typed and automatically propagating error system by the [Error Handling Rationale and Proposal](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst) document. As mentioned in that document, while this design works well in many situations, a manually propagated error type can enable even greater flexibility for error handling in Swift. Most commonly, developers using asynchronous APIs aren't served at all by the current error model. More generally, however, manual error propagation is useful for passing the results of a `throw`ing function without triggering automatic propagation or required handling, storing it locally, or otherwise working around awkwardness seen in certain scenarios when using the current automatic model. Additionally, the popularity of the `Result` type is well established, both in other languages and in Swift's own ecosystem. According to CocoaPods' statistics alone, Alamofire, which uses and exposes a `Result` type, is installed in over 490,000 apps. Additionally, the most popular standalone `Result` framework, [antitypical/Result](https://github.com/antitypical/Result), is installed in over 100,000.

Therefore, as the [Error Handling Rationale and Proposal](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst) document suggested it, and the Swift community has implemented it, this proposal would add `Result<T>` to the standard library. 

## Motivation

Outlined below are several scenarios in which `Result<T>` is commonly used.

### Asynchronous APIs

Most commonly, and seen in abundance when using Apple or Foundation APIs, `Result<T>` can serve to unify the awkwardly disparate parameters seen in asynchronous completion handlers. For instance, `URLSession`'s completion handlers take three optional parameters:

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

While this code is only a few lines long, it exposes Swift's complete lack of automatic error handling for asynchronous APIs. Not only was the `error` forcibly unwrapped (or perhaps handled using a slightly less elegant `if` statement), but a possibly impossible scenario was created. What happens if `response` or `data` are `nil`? Is it even possible? It shouldn't be, but Swift currently lacks the ability to express this impossibility. Using `Result<T>` for the same scenario allows for much more elegant code:

```swift
URLSession.shared.dataTask(with: url) { (result: Result<(URLResponse, Data)>) in // Type added for illustration purposes.
    switch result {
    case .success(let response):
        handleResponse(response.0, data: response.1)
    case .failure(let error):
        handleError(error)
    }
}
```

This API expresses exactly the intended result (either an error or data and response, never all or none) and allows them to be handled much more clearly. In fact, with the API outlined later in this proposal, we could make the handling even more succinct:

```swift
URLSession.shared.dataTask(with: url) { (result: Result<(URLResponse, Data)>) in // Type added for illustration purposes.
    result.withValue { handleResponse($0.0, data: $0.1) }
          .withError(handleError)
}
```
## General APIs

More generally, there are several scenarios in which `Result<T>` can make error handling and the surrounding APIs more elegant.

### Delayed Handling

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

This can be made somewhat cleaner by using a `(string: String?, error: Error?)` to store the result, but it would still have the same usage issues as in the asynchronous case. Using a `Result<T>` is the appropriate answer here, especially with the convenience API for creating a result from a `throw`ing function.

```swift
let configuration = Result { try String(contentsOfFile: configuration) }

// Sometime later...

func doSomethingWithConfiguration() {
    ...
}

```

### Separating Errors

It's occasionally useful to be able to run `throw`able functions in such way as to allow the developer to disambiguate between the sources of the errors, especially if the errors don't contain the information necessary to do, or the developer doesn't want to implement such a check. For instance, if we needed to disambiguate between the errors possible when reading files:

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
This case can be expressed much more clearly using `Result<T>`:

```swift
Result { try String(contentsOfFile: oneFile) }.withValue(handleOne)
                                              .withError(handleOneError)
Result { try String(contentsOfFile: twoFile) }.withValue(handleTwo)
                                              .withError(handleTwoError)
Result { try String(contentsOfFile: threeFile) }.withValue(handleThree)
                                                .withError(handleThreeError)
```

### General Usage

This proposal also outlines several other convenience APIs for `Result`, including transforms, success and failure closures, and the ability to convert a `Result` back into a throwing function, increasing instances where `Result` can be used to make otherwise awkward `do`/`try` blocks more elegant.

## Proposed solution

This proposal would directly port Alamofire's `Result<T>` type to the Swift standard library.

## Detailed design

```swift
/// Used to represent whether a request was successful or encountered an error.
///
/// - success: The request and all post processing operations were successful resulting in the serialization of the
///            provided associated value.
///
/// - failure: The request encountered an error resulting in a failure. The associated values are the original data
///            provided by the server as well as the error that caused the failure.
public enum Result<Value> {
    case success(Value)
    case failure(Error)

    /// Returns `true` if the result is a success, `false` otherwise.
    public var isSuccess: Bool {
        switch self {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    /// Returns `true` if the result is a failure, `false` otherwise.
    public var isFailure: Bool {
        return !isSuccess
    }

    /// Returns the associated value if the result is a success, `nil` otherwise.
    public var value: Value? {
        switch self {
        case .success(let value):
            return value
        case .failure:
            return nil
        }
    }

    /// Returns the associated error value if the result is a failure, `nil` otherwise.
    public var error: Error? {
        switch self {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }
}

// MARK: - CustomStringConvertible

extension Result: CustomStringConvertible {
    /// The textual representation used when written to an output stream, which includes whether the result was a
    /// success or failure.
    public var description: String {
        switch self {
        case .success:
            return "SUCCESS"
        case .failure:
            return "FAILURE"
        }
    }
}

// MARK: - CustomDebugStringConvertible

extension Result: CustomDebugStringConvertible {
    /// The debug textual representation used when written to an output stream, which includes whether the result was a
    /// success or failure in addition to the value or error.
    public var debugDescription: String {
        switch self {
        case .success(let value):
            return "SUCCESS: \(value)"
        case .failure(let error):
            return "FAILURE: \(error)"
        }
    }
}

// MARK: - Functional APIs

extension Result {
    /// Creates a `Result` instance from the result of a closure.
    ///
    /// A failure result is created when the closure throws, and a success result is created when the closure
    /// succeeds without throwing an error.
    ///
    ///     func someString() throws -> String { ... }
    ///
    ///     let result = Result(value: {
    ///         return try someString()
    ///     })
    ///
    ///     // The type of result is Result<String>
    ///
    /// The trailing closure syntax is also supported:
    ///
    ///     let result = Result { try someString() }
    ///
    /// - parameter value: The closure to execute and create the result for.
    public init(value: () throws -> Value) {
        do {
            self = try .success(value())
        } catch {
            self = .failure(error)
        }
    }

    /// Returns the success value, or throws the failure error.
    ///
    ///     let possibleString: Result<String> = .success("success")
    ///     try print(possibleString.unwrap())
    ///     // Prints "success"
    ///
    ///     let noString: Result<String> = .failure(error)
    ///     try print(noString.unwrap())
    ///     // Throws error
    public func unwrap() throws -> Value {
        switch self {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    /// Evaluates the specified closure when the `Result` is a success, passing the unwrapped value as a parameter.
    ///
    /// Use the `map` method with a closure that does not throw. For example:
    ///
    ///     let possibleData: Result<Data> = .success(Data())
    ///     let possibleInt = possibleData.map { $0.count }
    ///     try print(possibleInt.unwrap())
    ///     // Prints "0"
    ///
    ///     let noData: Result<Data> = .failure(error)
    ///     let noInt = noData.map { $0.count }
    ///     try print(noInt.unwrap())
    ///     // Throws error
    ///
    /// - parameter transform: A closure that takes the success value of the `Result` instance.
    ///
    /// - returns: A `Result` containing the result of the given closure. If this instance is a failure, returns the
    ///            same failure.
    public func map<T>(_ transform: (Value) -> T) -> Result<T> {
        switch self {
        case .success(let value):
            return .success(transform(value))
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Evaluates the specified closure when the `Result` is a success, passing the unwrapped value as a parameter.
    ///
    /// Use the `flatMap` method with a closure that may throw an error. For example:
    ///
    ///     let possibleData: Result<Data> = .success(Data(...))
    ///     let possibleObject = possibleData.flatMap {
    ///         try JSONSerialization.jsonObject(with: $0)
    ///     }
    ///
    /// - parameter transform: A closure that takes the success value of the instance.
    ///
    /// - returns: A `Result` containing the result of the given closure. If this instance is a failure, returns the
    ///            same failure.
    public func flatMap<T>(_ transform: (Value) throws -> T) -> Result<T> {
        switch self {
        case .success(let value):
            do {
                return try .success(transform(value))
            } catch {
                return .failure(error)
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Evaluates the specified closure when the `Result` is a failure, passing the unwrapped error as a parameter.
    ///
    /// Use the `mapError` function with a closure that does not throw. For example:
    ///
    ///     let possibleData: Result<Data> = .failure(someError)
    ///     let withMyError: Result<Data> = possibleData.mapError { MyError.error($0) }
    ///
    /// - Parameter transform: A closure that takes the error of the instance.
    /// - Returns: A `Result` instance containing the result of the transform. If this instance is a success, returns
    ///            the same instance.
    public func mapError<T: Error>(_ transform: (Error) -> T) -> Result {
        switch self {
        case .failure(let error):
            return .failure(transform(error))
        case .success:
            return self
        }
    }

    /// Evaluates the specified closure when the `Result` is a failure, passing the unwrapped error as a parameter.
    ///
    /// Use the `flatMapError` function with a closure that may throw an error. For example:
    ///
    ///     let possibleData: Result<Data> = .success(Data(...))
    ///     let possibleObject = possibleData.flatMapError {
    ///         try someFailableFunction(taking: $0)
    ///     }
    ///
    /// - Parameter transform: A throwing closure that takes the error of the instance.
    ///
    /// - Returns: A `Result` instance containing the result of the transform. If this instance is a success, returns
    ///            the same instance.
    public func flatMapError<T: Error>(_ transform: (Error) throws -> T) -> Result {
        switch self {
        case .failure(let error):
            do {
                return try .failure(transform(error))
            } catch {
                return .failure(error)
            }
        case .success:
            return self
        }
    }

    /// Evaluates the specified closure when the `Result` is a success, passing the unwrapped value as a parameter.
    ///
    /// Use the `withValue` function to evaluate the passed closure without modifying the `Result` instance.
    ///
    /// - Parameter closure: A closure that takes the success value of this instance.
    /// - Returns: This `Result` instance, unmodified.
    @discardableResult
    public func withValue(_ closure: (Value) -> Void) -> Result {
        if case let .success(value) = self { closure(value) }

        return self
    }

    /// Evaluates the specified closure when the `Result` is a failure, passing the unwrapped error as a parameter.
    ///
    /// Use the `withError` function to evaluate the passed closure without modifying the `Result` instance.
    ///
    /// - Parameter closure: A closure that takes the success value of this instance.
    /// - Returns: This `Result` instance, unmodified.
    @discardableResult
    public func withError(_ closure: (Error) -> Void) -> Result {
        if case let .failure(error) = self { closure(error) }

        return self
    }

    /// Evaluates the specified closure when the `Result` is a success.
    ///
    /// Use the `ifSuccess` function to evaluate the passed closure without modifying the `Result` instance.
    ///
    /// - Parameter closure: A `Void` closure.
    /// - Returns: This `Result` instance, unmodified.
    @discardableResult
    public func ifSuccess(_ closure: () -> Void) -> Result {
        if isSuccess { closure() }

        return self
    }

    /// Evaluates the specified closure when the `Result` is a failure.
    ///
    /// Use the `ifFailure` function to evaluate the passed closure without modifying the `Result` instance.
    ///
    /// - Parameter closure: A `Void` closure.
    /// - Returns: This `Result` instance, unmodified.
    @discardableResult
    public func ifFailure(_ closure: () -> Void) -> Result {
        if isFailure { closure() }

        return self
    }
}
```

## Source compatibility

This is a strictly additive feature, so no previous Swift code should be affected. Users of previous third-party `Result` types should be able to adopt the standard type very easily.

## Effect on ABI stability

As a high level feature there should be no affect on the ABI from adopting a `Result` type, as it's just an `enum`.

## Effect on API resilience

None directly, though adopting `Result` and later adding an `Either` type may not be ABI compatible if the desire is to make `Result` a type of `Either`.

## Alternatives considered
- `Result<T, E: Error>`: This was considered during the redesign of Alamofire's `Result` type for Swift 3. However, due to the `Error` type changes introduced, it was felt that interacting with `Error` returning APIs would be made far too awkward, as `Error` doesn't conform to itself. This would lead to users being forced to typecast those errors to some other type, likely `NSError`, which is not good practice.

- `Either<T, U>`: Rather than adopting `Result` directly, basing it on an `Either` type has been considered. However, it's felt that a `Result` type is a more generally useful case of `Either`, which gives users little in the way of actual API. Also, the two types can exist peacefully alongside each other with little conflict. Additionally, given the relatively unpopularity of the `Either` type in the community (48 apps use the [Either](https://github.com/runkmc/either) CocoaPod) seems to indicate that lacking this type isn't affecting Swift users that much.

