# Feature name

* Proposal: [SE-NNNN](NNNN-Results-Improvements.md)
* Authors: [hfhbd](https://github.com/hfhbd), [bojanstef](https://github.com/bojanstef)?, [tcldr](https://github.com/tcldr)?
* Review Manager: TBD
* Status: Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/27908), [apple/swift#NNNN](https://github.com/apple/swift/pull/26471)

## Introduction
In [SE-0235](https://github.com/apple/swift-evolution/blob/master/proposals/0235-add-result.md) the `Result` type was introduced.  
This type should be improved by a shortcut for `.success` and a function to recover the `Failure`.

Swift-evolution threads: [Never-failing Result Type](https://forums.swift.org/t/never-failing-result-type/30249/5), [Convenience member on Result when when Success is Void](https://forums.swift.org/t/convenience-member-on-result-when-when-success-is-void/36134)

## Motivation
The `Result` type is often used as state-ful return type, unified all across an API.
This sample API always returns a `Result` type. Technical for network APIs, a callback would be better, but for simplicity this is ignored.

```
struct API {
    enum APIError: Error {
        case network
        case malformedData
    }

    func getPhoto(of user: String) -> Result<Data, APIError> { 
        // ...
        .failure(.network) 
    }
    
    func update(photo: Data, of user: String) -> Result<Void, APIError> {
        // ...
        .success(())
    }
}

// Usage
func fetchJohnsPhoto() -> NSImage {
    let networkFallback: Data = Data()
    let dataFallback: Data = Data()
    let genericFallback: Data = Data()

    let maybePhoto: Result<Data, API.APIError> = API().getPhoto(of: "John Appleseed") //.failure(.network)
    func photoData(_ maybePhoto: Result<Data, API.APIError>) -> Data {
        do {
            return try maybePhoto.get()
        } catch { // 2. error is Error, not APIError
            guard let error = error as? API.APIError else { return genericFallback }
            switch(error) {
            case .network: return networkFallback
            case .malformedData: return dataFallback
            }
        }
    }
    let johnsPhoto = NSImage(data: photoData(maybePhoto))
    return johnsPhoto
}
```

1. To create a success case of a `Result<Void, Error>`, the call `Result<Void, Error>.success(())` is necessary. `Result<Void, Error>.success` would be much cleaner.

Sometimes an API call results into a failure, but the typed error should be discarded and replaced to an empty valid value, eg. a default value or `nil`. 

2. With the current `do { try result.get() } catch { error }` `error` is always `Error`, but not the type `APIError`.

This proposal adds this two additions: 
1. shorter creation of the success case
2. function to recover the failure, if present, to allow typed error handling

## Proposed solution

```
struct API {
    enum APIError: Error {
        case network
        case malformedData
    }

    func getPhoto(of user: String) -> Result<Data, APIError> { 
        // ...
        return .failure(.network) 
    }
    
    func update(photo: Data, of user: String) -> Result<Void, APIError> {
        // ...
        return .success // 1.
    }
}

// Usage
func fetchJohnsPhoto() -> NSImage {
    let networkFallback: Data = Data()
    let dataFallback: Data = Data()

    let maybePhoto = API().getPhoto(of: "John Appleseed") //.failure(.network)
    let johnsPhoto = maybePhoto.recoverFailure { error in // 2. error is now APIError
            switch(error) {
            case .network: return networkFallback
            case .malformedData: return dataFallback
            }
        }.map {
            NSImage(data: $0)
        }
        .get() // no try catch neccessary
    return johnsPhoto
}
```

To satisfy this requirements, this proposal is split into two parts:
1. Shortcut for `Result<Void, Error>.success(())`:
   - A helper static var is added to the `Result` type, if the Success value is `Void`.
1. Replace Failure:
   - Add `recoverFailure(transform:)` to `Result` to allow a typed error handling
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

### RecoverFailure
```
extension Result {
    public func recoverFailure(_ transform: (Failure) -> Success) -> Result<Success, Never> {
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
This proposal adds 2 public functions and 1 static variable via extensions to the frozen enum `Result`.

API resilience describes the changes one can make to a public API
without breaking its ABI. Does this proposal introduce features that
would become part of a public API? If so, what kinds of changes can be
made without breaking ABI? Can this feature be added/removed without
breaking ABI? For more information about the resilience model, see the
[library evolution
document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
in the Swift repository.

## Alternatives considered
Instead of wrapping the output of `recoverFailure(:)` to `Result<Success, Never>`, `Success` will be directly returned. 
```
extension Result {
    public func recoverFailure(_ transform: (Failure) -> Success) -> Success {
         switch self {
         case let .success(success):
             return success
         case let .failure(failure):
             return transform(failure)
         }
     }
}
```
