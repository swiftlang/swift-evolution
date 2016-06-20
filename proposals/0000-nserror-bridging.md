# NSError Bridging

* Proposal: [SE-NNNN](NNNN-nserror-bridging.md)
* Author: [Doug Gregor](https://github.com/DougGregor)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Swift's error handling model interoperates directly with Cocoa's
NSError conventions. For example, an Objective-C method with an
``NSError**`` parameter, e.g.,

```objc
- (nullable NSURL *)replaceItemAtURL:(NSURL *)url options:(NSFileVersionReplacingOptions)options error:(NSError **)error;
```

will be imported as a throwing method:

```swift
func replaceItem(at url: URL, options: ReplacingOptions = []) throws -> URL
```

Swift bridges between ``ErrorProtocol``-conforming types and
``NSError`` so, for example, a Swift ``enum`` that conforms to
``ErrorProtocol`` can be thrown and will be reflected as an
``NSError`` with a suitable domain and code. Moreover, an ``NSError``
produced with that domain and code can be caught as the Swift ``enum``
type, providing round-tripping so that Swift can deal in
``ErrorProtocol`` values while Objective-C deals in ``NSError``
objects.

However, the interoperability is incomplete in a number of ways, which
results in Swift programs having to walk a careful line between the
``ErrorProtocol``-based Swift way and the ``NSError``-based way. This
proposal attempts to bridge those gaps.

## Motivation

There are a number of weaknesses in Swift's interoperability with
Cocoa's error model, including:

1. There is no good way to provide important error information when
  throwing an error from Swift. For example, let's consider a simple
  application-defined error in Swift:

  ```swift
  enum HomeworkError : Int, ErrorProtocol {
    case forgotten
    case lost
    case dogAteIt
  }
  ```

  One can throw ``HomeworkError.dogAteIt`` and it can be interpreted
  as an ``NSError`` by Objective-C with an appropriate error domain
  (effectively, the mangled name of the ``HomeworkError`` type) and
  code (effectively, the case discriminator). However, one cannot
  provide a localized description, help anchor, recovery attempter, or
  any other information commonly placed into the ``userInfo``
  dictionary of an ``NSError``. To provide these values, one must
  specifically construct an ``NSError`` in Swift, e.g.,

  ```swift
  throw NSError(code: HomeworkError.dogAteIt.rawValue,
                domain: HomeworkError._domain,
                userInfo: [ NSLocalizedDescriptionKey : "the dog ate it" ])
  ```

2. There is no good way to get information typically associated with
  ``NSError``'s ``userInfo`` in Swift. For example, the Swift-natural
  way to catch a specific error in the ``AVError`` error domain doesn't
  give one access to the ``userInfo`` dictionary, e.g.,:

  ```swift
  catch let error as AVError where error == .diskFull {
    // AVError is an enum, so one only gets the equivalent of the code.
    // There is no way to access the localized description (for example) or
    // any other information typically stored in the ``userInfo`` dictionary.
  }
  ```

  The workaround is to catch as an ``NSError``, which is quite a bit
  more ugly:

  ```swift
  catch let error as NSError where error._domain == AVFoundationErrorDomain && error._code == AVFoundationErrorDomain.diskFull.rawValue {
    // okay: userInfo is accessible, but untyped
  }
  ```

  This makes it extremely hard to access common information, such as
  the localized description. Moreover, the ``userInfo`` dictionary is
  effectively untyped so, for example, one has to know a priori that
  the value associated with the known ``NSURLErrorKey`` will be typed
  as ``URL``:

  ```swift
  catch let error as NSError where error._domain = NSURLErrorDomain {
    if let url = error.userInfo[NSURLErrorKey] as? URL {
      // ...
    }
  }
  ```

  It would be far better if one could catch an ``NSURLError`` directly
  and query the URL in a type-safe manner:

  ```swift
  catch let error as NSURLError {
    if let url = error.url {
      // ...
    }
  }
  ```

3. ``NSError`` is inconsistently bridged with ``ErrorProtocol``. Swift
  interoperates by translating between ``NSError`` and ``ErrorProtocol``
  when mapping between a throwing Swift method/initializer and
  an Objective-C method with an ``NSError**`` parameter. However, an
  Objective-C method that takes an ``NSError*`` parameter (e.g., to
  render it) does not bridge to ``ErrorProtocol``, meaning that
  ``NSError`` is part of the API in Swift in some places (but not
  others). For example, ``NSError`` leaks through when the following
  ``UIDocument`` API in Objective-C:

  ```objc
  - (void)handleError:(NSError *)error userInteractionPermitted:(BOOL)userInteractionPermitted;
  ```

  is imported into Swift as follows:

  ```swift
  func handleError(_ error: NSError, userInteractionPermitted: Bool)
  ```

  One would expect the first parameter to be imported as ``ErrorProtocol``. 


## Proposed solution

The proposed solution involves directly addressing (1)-(3) with new
protocols and a different way of bridging Objective-C error code types
into Swift. There are roughly three parts:

1. Introduce one or more new protocols to allow an error type to
  expose additional information about errors that might be used by the
  UI, for example:

   ```swift
   /// Describes a type that has a localized description
   protocol LocalizedStringConvertible {
     var localizedDescription: String { get }
   }

   /// Describes an error for which one can attempt to recover
   protocol RecoverableError : ErrorProtocol {
     var localizedRecoveryOptions: [String]? { get }
     var localizedRecoverySuggestion: String? { get }
     var recoveryAttempter: NSErrorRecoveryAttempting? { get }
   }

   /// Describes an error type that fills in the userInfo directly.
   protocol CustomUserInfoError : ErrorProtocol {
     var userInfo: [NSObject : AnyObject] { get }
   }
   ```

   The actual protocol designs above are undoubtedly wrong. However,
   the intent is to allow Swift-defined error types to adopt these
   protocols to provide additional information about the errors
   (localized descriptions, recovery approaches, etc.). The bridging
   from Swift error types into ``NSError`` should popular the
   corresponding ``userInfo`` dictionary by dynamically querying these
   protocol conformances. For example, given:

   ```swift
   extension HomeworkError : LocalizedStringConvertible {
     var localizedDescription: String {
       switch self {
       case .forgotten: return NSLocalizedString("I forgot it")
       case .lost: return NSLocalizedString("I lost it")
       case .dogAteIt: return NSLocalizedString("The dog ate it")
       }
     }
   }

   extension HomeworkError : RecoverableError {
     var localizedRecoveryOptions: [String]? {
       return [ NSLocalizedString("Redo homework"),
                NSLocalizedString("Go to detention") ]
     }

     var localizedRecoverySuggestion: String? { ... }
     var recoveryAttempter: NSErrorRecoveryAttempting? { ... }
   }
   ```

   when ``HomeworkError`` is treated as an ``NSError``, the
   ``userInfo`` dictionary should be be populated with values for the
   keys ``NSLocalizedDescriptionKey``,
   ``NSLocalizedRecoveryOptionsErrorKey``,
   ``NSRecoveryAttempterErrorKey``, and so on by dynamically querying
   whether the type conforms to ``LocalizedStringConvertible``,
   ``RecoverableError``, and ``CustomUserInfoError``, then calling the
   appropriate entry points.

2. Imported Objective-C error types should be mapped to struct types
  that store an ``NSError`` so that no information is lost when
  bridging from an ``NSError`` to the Swift error types. For example,
  consider ``AVError``:

  ```objc
  typedef NS_ENUM(NSInteger, AVError) {
    AVErrorUnknown                                      = -11800,
    AVErrorOutOfMemory                                  = -11801,
    AVErrorSessionNotRunning                            = -11803,
    AVErrorDeviceAlreadyUsedByAnotherSession            = -11804,
    // ...
  }
  ```

  This is currently imported as an ``enum`` that conforms to
  ``ErrorProtocol``:

  ```swift
  enum AVError : Int, ErrorProtocol {
    case unknown                                      = -11800
    case outOfMemory                                  = -11801
    case sessionNotRunning                            = -11803
    case deviceAlreadyUsedByAnotherSession            = -11804

    static var _domain: String { return AVFoundationErrorDomain }
  }
  ```

  Instead, we will bridge to an ``AVError`` struct that contains
  an ``NSError``, so there is no information loss. The actual enum
  will become a nested type ``Code``, so that it is still
  accessible. The resulting struct will be as follows:

  ```swift
  struct AVError {
    /// Stored NSError. Note that error.domain == _domain is an invariant.
    private var error: NSError

    /// Describes the error codes; directly imported from AVError
    enum Code : Int {
      case unknown                                      = -11800
      case outOfMemory                                  = -11801
      case sessionNotRunning                            = -11803
      case deviceAlreadyUsedByAnotherSession            = -11804
    }

    /// Allow one to create an error with a userInfo dictionary.
    init(_ code: Code, userInfo: [NSObject: AnyObject] = [:]) {
      error = NSError(code: code.rawValue, domain: _domain, userInfo: userInfo)
    }

    /// Retrieve the code.
    var code: Code { return Code(rawValue: error.code)! }

    /// Allow direct access to the userInfo dictionary.
    var userInfo: [NSObject: AnyObject] { return error.userInfo }

    /// Make it easy to refer to constants. 
    static let unknown: Code = .unknown
    static let outOfMemory: Code = .outOfMemory
    static let sessionNotRunning: Code = .sessionNotRunning
    static let deviceAlreadyUsedByAnotherSession: Code = .deviceAlreadyUsedByAnotherSession
  }

  // Make AVError conform to ErrorProtocol
  extension AVError : ErrorProtocol {
    static var _domain: String { return AVFoundationErrorDomain }

    var _code: Int { return error.code }
  }
  ```

  This syntax allows one to throw specific errors fairly easily, with
  or without ``userInfo`` dictionaries:

  ```swift
  throw AVError(.sessionNotRunning)
  throw AVError(.sessionNotRunning, userInfo: [ ... ])
  ```

  With the addition of ``=~`` operator, we can make it easy to catch
  an ``AVError`` with a specific code:

  ```swift
  /// Code matching operator synthesized by the Clang importer
  func =~(lhs: AVError, rhs: AVError.Code) -> Bool {
    return lhs.code == rhs
  }

  catch AVError.outOfMemory {
    // ...
  }
  ```

  And to catch a specific error as a value one can reference:

  ```swift
  catch let error as AVError where error.code == .sessionNotRunning {
    // able to access userInfo here!
  }
  ```

  Note that this also makes it easy for an SDK overlay to provide
  type-specific accessors for known keys within the domain, e.g.,

  ```swift
  extension AVError {
    var device: String? {
      get {
        return error.userInfo[AVErrorDeviceKey] as? String?
      }

      set {
        error.userInfo[AVErrorDeviceKey] = newValue.map { $0 as NSString }
      }
    }

    var time: CMTime? {
      get {
        return error.userInfo[AVErrorTimeKey] as? CMTime?
      }

      set {
        error.userInfo[AVErrorTimeKey] = newValue.map { $0 as CMTime }
      }
    }
  }
  ```

  which provides additional safety over an unstructured ``userInfo``
  dictionary. One could also provide other conveniences, e.g.,
  initializers that make it easy to provide values for known keys
  within the domain.

3. Bridge ``NSError`` to ``ErrorProtocol``, so that all ``NSError``
uses are bridged consistently. For example, this means that the
Objective-C API:

  ```objc
  - (void)handleError:(NSError *)error userInteractionPermitted:(BOOL)userInteractionPermitted;
  ```

  is imported into Swift as:

  ```swift
  func handleError(_ error: ErrorProtocol, userInteractionPermitted: Bool)
  ```

  This will use the same bridging logic in the Clang importer that we
  use for other value types (``Array``, ``String``, ``URL``, etc.),
  but with the runtime translation we've already been doing for
  catching/throwing errors.

  When we introduce this bridging, we will need to remove
  ``NSError``'s conformance to ``ErrorProtocol`` to avoid creating
  cyclic implicit conversions. However, we still need an easy way to
  create an ``ErrorProtocol`` instance from an arbitrary ``NSError``,
  e.g.,

  ```swift
  extension NSError {
    var asError: ErrorProtocol { ... }
  }
  ```

  Once we've completed the bridging story, ``ErrorProtocol`` becomes
  the primary way to work with error types in Swift, and the value
  type to which ``NSError`` is bridged. We should rename it to
  ``Error``:

  ```swift
  func handleError(_ error: Error, userInteractionPermitted: Bool)
  ```

## Other Issues

``NSError`` codes and domains are important for localization of error
messages. This is barely supported today by ``genstrings``, but
becomes considerably harder when the domain and code are hidden (as
they are in Swift). We would need to consider tooling to make it
easier to localize error descriptions, recovery options, etc. in a
sensible way. Although this is out of the scope of the Swift language
per se, it's an important part of the developer story.

## Detailed design

TODO: More details about the protocols (when we figure it out), 

## Impact on existing code

TODO: WRITE ME

