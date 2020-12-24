# Concurrency Interoperability with Objective-C

* Proposal: [SE-0297](0297-concurrency-objc.md)
* Author: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Accepted With Modifications** 
* [Acceptance Post](https://forums.swift.org/t/accepted-with-modifications-se-0297-concurrency-interoperability-with-objective-c/43306)
* Implementation: Partially available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Table of Contents

* [Introduction](#introduction)
* [Motivation](#motivation)
* [Proposed solution](#proposed-solution)
* [Detailed design](#detailed-design)
   * [Asynchronous completion-handler methods](#asynchronous-completion-handler-methods)
   * [Defining asynchronous @objc methods in Swift](#defining-asynchronous-objc-methods-in-swift)
   * [Actor classes](#actor-classes)
   * [Completion handlers must be called exactly once](#completion-handlers-must-be-called-exactly-once)
   * [Additional Objective-C attributes](#additional-objective-c-attributes)
* [Source compatibility](#source-compatibility)
* [Revision history](#revision-history)
* [Future Directions](#future-directions)
   * [NSProgress](#nsprogress)

## Introduction

Swift's concurrency feature involves asynchronous functions and actors. While Objective-C does not have corresponding language features, asynchronous APIs are common in Objective-C, expressed manually through the use of completion handlers. This proposal provides bridging between Swift's concurrency features (e.g., `async` functions) and the convention-based expression of asynchronous functions in Objective-C. It is intended to allow the wealth of existing asynchronous Objective-C APIs to be immediately usable with Swift's concurrency model.

For example, consider the following Objective-C API in [CloudKit](https://developer.apple.com/documentation/cloudkit/ckcontainer/1640387-fetchshareparticipantwithuserrec):

```objc
- (void)fetchShareParticipantWithUserRecordID:(CKRecordID *)userRecordID 
    completionHandler:(void (^)(CKShareParticipant * _Nullable, NSError * _Nullable))completionHandler;
```

This API is asynchronous. It delivers its result (or an error) via completion handler. The API directly translates into Swift:

```swift
func fetchShareParticipant(
    withUserRecordID userRecordID: CKRecord.ID, 
    completionHandler: @escaping (CKShare.Participant?, Error?) -> Void
)
```

Existing Swift code can call this API by passing a closure for the completion handler. This proposal provides an alternate Swift translation of the API into an `async` function, e.g.,

```swift
func fetchShareParticipant(
    withUserRecordID userRecordID: CKRecord.ID
) async throws -> CKShare.Participant
```

Swift callers can invoke `fetchShareParticipant(withUserRecordID:)` within an `await` expression:

```swift
guard let participant = try? await container.fetchShareParticipant(withUserRecordID: user) else {
    return nil
}
```

Swift-evolution thread: [\[Concurrency\] Interoperability with Objective-C](https://forums.swift.org/t/concurrency-interoperability-with-objective-c/41616)

## Motivation

On Apple platforms, Swift's tight integration with Objective-C APIs is an important part of the developer experience. There are several core features:

* Objective-C classes, protocols, and methods can be used directly from Swift.
* Swift classes can subclass Objective-C classes.
* Swift classes can declare conformance to Objective-C protocols.
* Swift classes, protocols, and methods can be made available to Objective-C via the `@objc` attribute.

Asynchronous APIs abound in Objective-C code: the iOS 14.0 SDK includes nearly 1,000 methods that accept completion handlers. These include methods that one could call directly from Swift, methods that one would override in a Swift-defined subclass, and methods in protocols that one would conform to. Supporting these use cases in Swift's concurrency model greatly expands the reach of this new feature. 

## Proposed solution

The proposed solution provides interoperability between Swift's concurrency constructs and Objective-C in various places. It has several inter-dependent pieces:

* Translate Objective-C completion-handler methods into `async` methods in Swift.
* Allow `async` methods defined in Swift to be `@objc`, in which case they are exported as completion-handler methods.
* Provide Objective-C attributes to control over how completion-handler-based APIs are translated into `async` Swift functions.

The detailed design section describes the specific rules and heuristics being applied. However, the best way to evaluate the overall effectiveness of the translation is to see its effect over a large number of Objective-C APIs. [This pull request](https://github.com/DougGregor/swift-concurrency-objc/pull/1) demonstrates the effect that this proposal has on the Swift translations of Objective-C APIs across the Apple iOS, macOS, tvOS, and watchOS SDKs.

## Detailed design

### Asynchronous completion-handler methods

An Objective-C method is potentially an asynchronous completion-handler method if it meets the following requirements:

* The method has a completion handler parameter, which is an Objective-C block that will receive the "result" of the asynchronous computation. It must meet the following additional constraints:
  * It has a `void` result type.
  * It is called exactly once along all execution paths through the implementation.
  * If the method can deliver an error, one of the parameters of the block is of type `NSError *` that is not `_Nonnull`. A non-nil `NSError *` value typically indicates that an error occurred, although the C `swift_async` attribute can describe other conventions (discussed in the section on Objective-C attributes).
* The method itself has a `void` result type, because all results are delivered by the completion handler block.

An Objective-C method that is potentially an asynchronous completion-handler method will be translated into an `async` method when it is either annotated explicitly with an appropriate `swift_async` attribute (described in the section on Objective-C attributes) or is implicitly inferred when the following heuristics successfully identify the completion handler parameter:

* If the method has a single parameter, and the suffix of the first selector piece is one of the following phrases:
  - `WithCompletion`
  - `WithCompletionHandler`
  - `WithCompletionBlock`
  - `WithReplyTo`
  - `WithReply`
  the sole parameter is the completion handler parameter. The matching phrase will be removed from the base name of the function when it is imported.
* If the method has more than one parameter, the last parameter is the completion handler parameter if its selector piece or parameter name is `completion`, `withCompletion`, `completionHandler`, `withCompletionHandler`, `completionBlock`, `withCompletionBlock`, `replyTo`, `withReplyTo`,  `reply`, or `replyTo`.
* If the method has more than one parameter, and the last parameter ends with one of the suffixes from the first bullet, the last parameter is the completion handler. The text preceding the suffix is appended to the base name of the function.

When the completion handler parameter is inferred, the presence of an `NSError *` parameter that is not `_Nonnull` in the completion handler block type indicates that the translated method can deliver an error.

The translation of an asynchronous Objective-C completion-handler method into an `async` Swift method follows the normal translation procedure, with the following alterations:

* The completion handler parameter is removed from the parameter list of the translated Swift method.
* If the method can deliver an error, it is `throws` in addition to being `async`.
* The parameter types of the completion handler block type are translated into the result type of the `async` method, subject to the following additional rules:
  * If the method can deliver an error, the `NSError *` parameter is ignored. 
  * If the method can deliver an error and a given parameter has the `_Nullable_result` nullability qualifier (see the section on Objective-C attributes below), it will be imported as optional. Otherwise, it will be imported as non-optional.
  * If there are multiple parameter types, they will be combined into a tuple type.

The following [PassKit API](https://developer.apple.com/documentation/passkit/pkpasslibrary/3543357-signdata?language=objc) demonstrates how the inference rule plays out:

```objc
- (void)signData:(NSData *)signData 
withSecureElementPass:(PKSecureElementPass *)secureElementPass 
      completion:(void (^)(NSData *signedData, NSData *signature, NSError *error))completion;
```

Today, this is translated into the following completion-handler function in Swift:

```swift
@objc func sign(_ signData: Data, 
    using secureElementPass: PKSecureElementPass, 
    completion: @escaping (Data?, Data?, Error?) -> Void
)
```

This will be translated into the following `async` function:

```swift
@objc func sign(
    _ signData: Data, 
    using secureElementPass: PKSecureElementPass
) async throws -> (Data, Data)
```

When the compiler sees a call to such a method, it effectively uses `withUnsafeContinuation` to form a continuation for the rest of the function, then wraps the given continuation in a closure. For example:

```swift
let (signedValue, signature) = try await passLibrary.sign(signData, using: pass)
```

becomes pseudo-code similar to

```swift
try withUnsafeContinuation { continuation in 
    passLibrary.sign(
        signData, using: pass, 
        completionHandler: { (signedValue, signature, error) in
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: (signedValue!, signature!))
            }
        }
    )
}
```

Additional rules are applied when translating an Objective-C method name into a Swift name of an `async` function:

* If the base name of the method starts with `get`, the `get` is removed and the leading initialisms are lowercased.
* If the base name of the method ends with `Asynchronously`, that word is removed.

If the completion-handler parameter of the Objective-C method is nullable and the translated `async` method returns non-`Void`, it will be marked with the `@discardableResult` attribute. For example:

```objc
-(void)stopRecordingWithCompletionHandler:void(^ _Nullable)(RPPreviewViewController * _Nullable, NSError * _Nullable)handler;
```

will become:

```swift
@discardableResult func stopRecording() async throws -> RPPreviewViewController
```

### Defining asynchronous `@objc` methods in Swift

Many Swift entities can be exposed to Objective-C via the `@objc` attribute. With an `async` Swift method, the compiler will add an appropriate completion-handler parameter to the Objective-C method it creates, using what is effectively the inverse of the transformation described in the previous section, such that the Objective-C method produced is an asynchronous Objective-C completion-handler method. For example, a method such as:

```swift
@objc func perform(operation: String) async -> Int { ... }
```

will translate into the following Objective-C method:

```objc
- (void)performWithOperation:(NSString * _Nonnull)operation
           completionHandler:(void (^ _Nullable)(NSInteger))completionHandler;
```

The Objective-C method implementation synthesized by the compiler will create a detached task that calls the `async` Swift method `perform(operation:)` with the given string, then (if the completion handler argument is not `nil`) forwards the result to the completion handler.

For an `async throws` method, the completion handler is extended with an `NSError *` parameter to indicate the error, any non-nullable pointer type parameters are made `_Nullable`, and any nullable pointer type parameters are made `_Nullable_result`. For example, given:

```swift
@objc func performDangerousTrick(operation: String) async throws -> String { ... }
```

the resulting Objective-C method will have the following signature:

```objc
- (void)performDangerousTrickWithOperation:(NSString * _Nonnull)operation
    completionHandler:(void (^ _Nullable)(NSString * _Nullable, NSError * _Nullable))completionHandler;
```

Again, the synthesized Objective-C method implementation will create a detached task that calls the `async throws` method `performDangerousTrick(operation:)`. If the method returns normally, the `String` result will be delivered to the completion handler in the first parameter and the second parameter (`NSError *`) will be passed `nil`. If the method throws, the first parameter will be passed `nil` (which is why it has been made `_Nullable` despite being non-optional in Swift) and the second parameter will receive the error. If there are non-pointer parameters, they will be passed zero-initialized memory in the non-error arguments to provide consistent behavior for callers. This can be demonstrated with Swift pseudo-code:

```swift
// Synthesized by the compiler
@objc func performDangerousTrick(
    operation: String,
    completionHandler: ((String?, Error?) -> Void)?
) {
    runDetached {
        do {
            let value = try await performDangerousTrick(operation: operation)
            completionHandler?(value, nil)
        } catch {
            completionHandler?(nil, error)
        }
    }
}
```

### Actor classes

Actor classes can be `@objc` and will be available in Objective-C as are other classes. Actor classes require that their superclass (if there is one) also be an actor class. However, this proposal loosens that requirement slightly to allow an actor class to have `NSObject` as its superclass. This is conceptually safe because `NSObject` has no state (and its layout is effectively fixed that way), and makes it possible both for actor classes to be `@objc` and also implies conformance to `NSObjectProtocol`, which is required when conforming to a number of Objective-C protocols and is otherwise unimplementable in Swift. 

A member of an actor class can only be `@objc` if it is either `async` or is outside of the actor's isolation domain. Synchronous code that is within the actor's isolation domain can only be invoked on `self` (in Swift). Objective-C does not have knowledge of actor isolation, so these members are not permitted to be exposed to Objective-C. For example:

```swift
actor class MyActor {
    @objc func synchronous() { } // error: part of actor's isolation domain
    @objc func asynchronous() async { } // okay: asynchronous
    @objc @actorIndependent func independent() { } // okay: actor-independent
}
```

### Completion handlers must be called exactly once

A Swift `async` function will always suspend, return, or (if it throws) produce an error. For completion-handler APIs, it is important that the completion handler block be called exactly once on all paths, including when producing an error. Failure to do so will break the semantics of the caller, either by failing to continue or by executing the same code multiple times. While this is an existing problem, widespread use of `async` with incorrectly-implemented completion-handler APIs might exacerbate the issue.

Fortunately, because the compiler itself is synthesizing the block that will be passed to completion-handler APIs, it can detect both problems by introducing an extra bit of state into the synthesized block to indicate that the block has been called. If the bit is already set when the block is called, then it has been called multiple times. If the bit is not set when the block is destroyed, it has not been called at all. While this does not fix the underlying problem, it can at least detect the issue consistently at run time.

### Additional Objective-C attributes 

The transformation of Objective-C completion-handler-based APIs to async Swift APIs could benefit from the introduction of additional annotations (in the form of attributes) to guide the process. For example:

* `_Nullable_result`. Like `_Nullable`, indicates that a pointer can be null (or `nil`). `_Nullable_result` differs from `_Nullable` only for parameters to completion handler blocks. When the completion handler block's parameters are translated into the result type of an `async` method, the corresponding result will be optional.
* `__attribute__((swift_async(...)))`. An attribute to control the translation of an asynchronous completion-handler method to an `async` function. It has several operations within the parentheses:
  * `__attribute__((swift_async(none)))`. Disables the translation to `async`.  
  * `__attribute__((swift_async(not_swift_private, C)))`. Specifies that the method should be translated into an `async` method, using the parameter at index `C` as the completion handler parameter. The first (non-`self`) parameter has index 1.
  * `__attribute__((swift_async(swift_private, C)))`. Specifies that the method should be translated into an `async` method that is "Swift private" (only for use when wrapping), using the parameter at index `C` as the completion handler parameter. The first (non-`self`) parameter has index 1.
* `__attribute__((swift_attr("swift attribute")))`. A general-purpose Objective-C attribute to allow one to provide Swift attributes directly. In the context of concurrency, this allows Objective-C APIs to be annotated with a global actor (e.g., `@UIActor`).
* `__attribute__((swift_async_name("method(param1:param2:)")))`. Specifies the Swift name that should be used for the `async` translation of the API. The name should not include an argument label for the completion handler parameter.
* `__attribute__((swift_async_error(...)))`. An attribute to control how passing an `NSError *` into the completion handle maps into the method being `async throws`. It has several possible parameters:
  * `__attribute__((swift_async_error(none)))`: Do not import as `throws`. The `NSError *` parameter will be considered a normal parameter.
  * `__attribute__((swift_async_error(zero_argument(N)))`: Import as `throws`. When the Nth argument to the completion handler is passed the integral value zero (including `false`), the async method will throw the error. The Nth argument is removed from the result type of the translated `async` method. The first argument is `0`.
  * `__attribute__((swift_async_error(nonzero_argument(N)))`: Import as `throws`. When the Nth argument to the completion handler is passed a non-zero integral value (including `true`), the async method will throw the error. The Nth argument is removed from the result type of the translated `async` method.


## Source compatibility

Generally speaking, changes to the way in which Objective-C APIs are translated into Swift are source-breaking changes. To avoid breaking source compatibility, this proposal involves translating Objective-C asynchronous completion-handler methods as *both* their original completion-handler signatures and also with the new `async` signature. This allows existing Swift code bases to gradually adopt the `async` forms of API, rather than forcing (e.g.) an entire Swift module to adopt `async` all at once.

Importing the same Objective-C API in two different ways causes some issues:

* Overloading of synchronous and asynchronous APIs. Objective-C frameworks may have evolved to include both synchronous and asynchronous versions of the same API, e.g.,

  ```objc
  - (NSString *)lookupName;
  - (void)lookupNameWithCompletionHandler:(void (^)(NSString *))completion;
  ```
  which will be translated into three different Swift methods:
  
  ```swift
  @objc func lookupName() -> String
  @objc func lookupName(withCompletionHandler: @escaping (String) -> Void)
  @objc func lookupName() async -> String
  ```
  
  The first and third signatures are identical except for being synchronous and asynchronous, respectively. The async/await design doesn't allow such overloading to be written in the same Swift module, but it can happen when translating Objective-C APIs or when importing methods from different Swift modules. The async/await design accounts for such overloading by favoring synchronous functions in synchronous contexts and asynchronous functions in asynchronous contexts. This overloading should avoid breaking source compatibility.

* Another issue is when an asynchronous completion-handler method is part of an Objective-C protocol. For example, the [`NSURLSessionDataDelegate` protocol](https://developer.apple.com/documentation/foundation/nsurlsessiondatadelegate?language=objc) includes this protocol requirement:

  ```objc
  @optional
  - (void)URLSession:(NSURLSession *)session
            dataTask:(NSURLSessionDataTask *)dataTask
  didReceiveResponse:(NSURLResponse *)response
   completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler;
  ```

  Existing Swift code might implement this requirement in a conforming type using its completion-handler signature

  ```swift
  @objc
  func urlSession(
      _ session: URLSession,
      dataTask: URLSessionDataTask,
      didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) { ... }
  ```

  while Swift code designed to take advantage of the concurrency model would implement this requirement in a conforming type using its `async` signature

  ```swift
  @objc
  func urlSession(
      _ session: URLSession,
      dataTask: URLSessionDataTask,
      didReceive response: URLResponse
  ) async -> URLSession.ResponseDisposition { ... }
  ```

  Implementing both requirements would produce an error (due to two Swift methods having the same selector), but under the normal Swift rules implementing only one of the requirements will also produce an error (because the other requirement is unsatisfied). Swift’s checking of protocol conformances will be extended to handle the case where multiple (imported) requirements have the same Objective-C selector: in that case, only one of them will be required to be implemented.
  
* Overriding methods that have been translated into both completion-handler and `async` versions have a similar problem to protocol requirements: a Swift subclass can either override the completion-handler version or the `async` version, but not both. Objective-C callers will always call to the subclass version of the method, but Swift callers to the "other" signature will not unless the subclass's method is marked with `@objc dynamic`. Swift can infer that the `async` overrides of such methods are `@objc dynamic` to avoid this problem (because such `async` methods are new code). However, inferring `@objc dynamic` on existing completion-handler overrides can change the behavior of programs and break subclasses of the subclasses, so at best the compiler can warn about this situation.

## Revision history

* Post-review:
   * `await try` becomes `try await` based on result of SE-0296 review
   * Added inference of `@discardableResult` for `async` methods translated from completion-handler methods with an optional completion handler.
* Changes in the second pitch:
	* Removed mention of asynchronous handlers, which will be in a separate proposal.
	* Introduced the `swift_async_error` Clang attribute to separate out "throwing" behavior from the `swift_async` attribute.
	* Added support for "Swift private" to the `swift_async` attribute.
	* Tuned the naming heuristics based on feedback to add (e.g) `reply`, `replyTo`, `completionBlock`, and variants.
	* For the rare case where we match a parameter suffix, append the text prior to the suffix to the base name.
	* Replaced the `-generateCGImagesAsynchronouslyForTimes:completionHandler:` example with one from PassKit.
	* Added a "Future Directions" section about `NSProgress`.

* Original pitch ([document](https://github.com/DougGregor/swift-evolution/blob/9b9bdfd16eb5ced390913ea170007a46eabb08eb/proposals/NNNN-concurrency-objc.md) and [forum thread](https://forums.swift.org/t/concurrency-interoperability-with-objective-c/41616)).

## Future Directions

### NSProgress

Some Objective-C completion-handler methods return an [NSProgress](https://developer.apple.com/documentation/foundation/progress) to allow the caller to evaluate progress of the asynchronous operation. Such methods are *not* imported as `async` in this proposal, because the method does not return `void`. For example:

```swift
- (NSProgress *)doSomethingThatTakesALongTimeWithCompletionHandler:(void (^)(MyResult * _Nullable, NSError * _Nullable))completionHandler;
```

To support such methods would require some kind of integration between `NSProgress` and Swift's tasks. For example, when calling such a method, the `NSProgress` returned from such a call to be recorded in the task (say, in some kind of task-local storage). The other direction, where a Swift-defined method overrides a method, would need to extract an `NSProgress` from the task to return. Such a design is out of scope for this proposal, but could be introduced at some later point.
