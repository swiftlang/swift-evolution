# Add Result<T> To The Standard Library

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Jon Shier](https://github.com/jshier)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

A common desire for those using asynchronous APIs or wanting to pass the results of a throwing function around is the existence of a `Result` type. In addition, libraries adding this functionality currently exist and are quite popular. 

## Motivation

Currently, asynchronous error handling beyond simple error-capturing closures requires manual or third-party implementation for all Swift users. Adding a type that allows the capture of not only all asynchronous results but the encapsulation of the result of any throwing closure. Additionally, the popularity of the `Result` type, both in other languages and in Swift's own ecosystem, indicates that it should be part of the standard library. According to CocoaPods' statistics alone, Alamofire is installed in over 490,000 apps. Additionally, the most popular standalone `Result` framework, [antitypical/Result](https://github.com/antitypical/Result), is installed in over 100,000.

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
- `Result<T, Error>`: This was considered during the redesign of Alamofire's `Result` type for Swift 3. However, due to the `Error` type changes introduced, it was felt that interacting with `Error` returning APIs would be made far too awkward, as `Error` doesn't conform to itself. This would lead to users being forced to typecast those errors to some other type, likely `NSError`, which is not good practice.

- `Either<T, U>`: Rather than adopting `Result` directly, basing it on an `Either` type has been considered. However, it's felt that a `Result` type is a more generally useful case of `Either`, which gives users little in the way of actual API. Also, the two types can exist peacefully alongside each other with little conflict. Additionally, given the relatively unpopularity of the `Either` type in the community (48 apps use the [Either](https://github.com/runkmc/either) CocoaPod) seems to indicate that lacking this type isn't affecting Swift users that much.

