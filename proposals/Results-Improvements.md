# Feature name

* Proposal: [SE-NNNN](NNNN-Results-Improvements.md)
* Authors: [hfhbd](https://github.com/hfhbd), [bojanstef](https://github.com/bojanstef)?, [tcldr](https://github.com/tcldr)?
* Review Manager: TBD
* Status: Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/27908), [apple/swift#NNNN](https://github.com/apple/swift/pull/26471)

## Introduction
In [SE-0235](https://github.com/apple/swift-evolution/blob/master/proposals/0235-add-result.md) the `Result` type was introduced.
This type should be improved by several functions and shortcuts.

Swift-evolution thread: [Never-failing Result Type](https://forums.swift.org/t/never-failing-result-type/30249/5), [Convenience member on Result when when Success is Void](https://forums.swift.org/t/convenience-member-on-result-when-when-success-is-void/36134)

## Motivation
The `Result` type is often used as state-ful return type, unified all across an API.

```
struct API {
    enum APIError: Error {
        case .network
        case .invalid(request: String, response: String)
    }

    func getPhoto(of user: String, result: Result<Data, APIError>) { ... }
    
    func update(photo: Data, of user: String, result: Result<Void, APIError>) { 
        let response: Response = ...
        if ((200..<300).contains(response.status) ) {
            return .success(()) // 1. 
        }
        ...
    }
}

// Usage
let networkFallback: Data = ...
let storageFallback: Data = ...
let genericFallback: Data = ...

let maybePhoto = getPhoto(of: "John Appleseed") //.failure(.network)
let johnsPhoto: UIImage
try { 
    johnsPhoto = UIImage(data: maybePhoto.get()) 
} catch { error in // 2. err is Error, not APIError
    guard let error = error as? APIError else { return UIImage(data: genericFallback) } 
    switch(error) {     
    case .network: return UIImage(data: networkFallback)
    case .storage: return UIImage(data: storageFallback)
}
```

This sample API always returns a callback with a `Result` type, even the function `update(user:result:)`.
1. To create a success case of a `Result<Void, Error>`, the call `Result<Void, Error>.success(())` is necessary.

Sometimes an API call results into a failure, but the typed error should be discarded and replaced to an empty valid value, eg. a default value or `nil`. 
2. With the current `try { result.get() } catch { error }` `error` is always `Error`, but not typed.

This proposal adds this two additions: 
1. shorter creation of the success case
2. function to replace the failure, if present, to allow typed error handling

## Proposed solution

```
struct API {
    enum APIError: Error {
        case .network
        case .invalid(request: String, response: String)
    }

    func getPhoto(of user: String, result: Result<Data, APIError>) { ... }
    func getPhoto(of user: String, result: Result<User, APIError>) { ... }
    
    func update(photo: Data, of user: String, result: Result<Void, APIError>) { 
        let response: Response = ...
        if ((200..<300).contains(response.status) ) {
            return .success // 1. 
        }
        ...
    }
}

// Usage
let networkFallback: Data = ...
let storageFallback: Data = ...

let maybePhoto = getPhoto(of: "John Appleseed") //.failure(.network)
let johnsPhoto = maybePhoto.replaceFailure { err in // 2. err is now APIError
         switch(err) {
         case .network: return networkFallback
         case .storage: return storageFallback
         }
     }.map {
         UIImage(data: $0)
     }
     .get() // no try catch neccessary
```

To satisfy this requirements, this proposal is split into two parts:
1. Shortcut for `Result<Void, Error>.success(())`:
   - A helper static var is added to the `Result` type, if the Success value is `Void`.
1. Replace Failure:
   - Add `replaceFailure(transform:)` to `Result` to allow a typed error handling
   - Overload `get() throws` with `get()` when `Failure` is `Never`
   
## Detailed design

### Success Shortcut
```
extension Result where Success == Void {
   public static var success: Result<Success, Failure> {
     return .success(())
   }
}

// Usage
let r: Result<Void, Error> = .success
```

### ReplaceFailure
```
extension Result {
    public func replaceFailure(_ transform: (Failure) -> Success) -> Result<Success, Never> {
         switch self {
         case let .success(success):
             return .success(success)
         case let .failure(failure):
             return .success(transform(failure))
         }
     }
}

extension Result where Failure == Never {
     public func get() -> Success {
         switch self {
         case let .success(success):
             return success
         }
     }
 }
 ```

## Source compatibility
This is a purely additive change.

## Effect on ABI stability
This is a purely additive change.

## Effect on API resilience

API resilience describes the changes one can make to a public API
without breaking its ABI. Does this proposal introduce features that
would become part of a public API? If so, what kinds of changes can be
made without breaking ABI? Can this feature be added/removed without
breaking ABI? For more information about the resilience model, see the
[library evolution
document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
in the Swift repository.

## Alternatives considered

Describe alternative approaches to addressing the same problem, and
why you chose this approach instead.
