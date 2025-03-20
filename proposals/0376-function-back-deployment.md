# Function Back Deployment

* Proposal: [SE-0376](0376-function-back-deployment.md)
* Author: [Allan Shortlidge](https://github.com/tshortli)
* Implementation: [apple/swift#41271](https://github.com/apple/swift/pull/41271), [apple/swift#41348](https://github.com/apple/swift/pull/41348), [apple/swift#41416](https://github.com/apple/swift/pull/41416), [apple/swift#41612](https://github.com/apple/swift/pull/41612) as the underscored attribute `@_backDeploy`
* Review Manager: [Frederick Kellison-Linn](https://github.com/jumhyn)
* Review: ([pitch](https://forums.swift.org/t/pitch-function-back-deployment/55769)) ([review](https://forums.swift.org/t/se-0376-function-back-deployment/61015)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0376-function-back-deployment/61507)) ([second review](https://forums.swift.org/t/se-0376-second-review-function-back-deployment/61671)) ([returned for revision (second review)](https://forums.swift.org/t/returned-for-revision-se-0376-second-review-function-back-deployment/62374))([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0376-function-back-deployment/62905))
* Status: **Implemented (Swift 5.8)**

## Introduction

This proposal introduces a `@backDeployed` attribute to allow ABI-stable libraries to make their own public APIs available on older OSes. When a `@backDeployed` API isn't present in the library that ships with an older OS, a client running on that OS can still use the API because a fallback copy of its implementation has been emitted into the client.

With `@backDeployed`, a function may be emitted into clients as a fallback copy of _itself_. Note that the attribute doesn't mark a function as a fallback implementation of some _other_ function, and therefore it doesn't help one module to extend the availability of APIs declared in some _other_ module.

## Motivation

Resilient Swift libraries, such as the ones present in the SDKs for Apple's platforms, are distributed as dynamic libraries. Authors of these libraries use `@available` annotations to indicate the operating system version that a declaration was introduced in. For example, suppose this were the interface of ToastKit, a library that is part of the toasterOS SDK:

```swift
@available(toasterOS 1.0, *)
public struct BreadSlice { ... }

@available(toasterOS 1.0, *)
public struct Toast { ... }

@available(toasterOS 1.0, *)
public struct Toaster {
  public func makeToast(_ slice: BreadSlice) -> Toast
}
```

In response to developer feedback, the ToastKit authors enhance `Toaster` in toasterOS 2.0 with the capability to make toast in batches:

```swift
extension Toaster {
  @available(toasterOS 2.0, *)
  public func makeBatchOfToast(_ slices: [BreadSlice]) -> [Toast] {
    var toast: [Toast] = []
    for slice in slices {
      toast.append(makeToast(slice))
    }
    return toast
  }
}
```

Unfortunately, developers who wish to both distribute an app compatible with toasterOS 1.0 and also adopt `makeBatchOfToast(_:)` must call the API conditionally to account for its potential unavailability:

```swift
let slices: [BreadSlice] = ...
if #available(toasterOS 2.0, *) {
  let toast = toaster.makeBatchOfToast(slices)
  // ...
} else {
  // ... do something else, like reimplement makeBatchOfToast(_:)
}
```

Considering that the implementation of `makeBatchOfToast(_:)` is self contained and could run unmodified on toasterOS 1.0, it would be ideal if the ToastKit authors had the option to back deploy this new API to older OSes and allow clients to adopt it unconditionally.

The `@_alwaysEmitIntoClient` attribute is an unofficial Swift language feature that can be used to solve this problem. The bodies of functions with this attribute are emitted into the library's `.swiftinterface` (similarly to `@inlinable` functions) and the compiler makes a local copy of the annotated function in the client module. References to these functions _always_ resolve to a copy in the same module so the function is effectively not a part of the library's ABI.

While `@_alwaysEmitIntoClient` can be used to back deploy APIs, there are some drawbacks to using it. Since a copy of the function is always emitted, there is code size overhead for every client even if the client's deployment target is new enough that the library API would always be available at runtime. Additionally, if the implementation of the API were to change in order to improve performance, fix a bug, or close a security hole then the client would need to be recompiled against a new SDK before users benefit from those changes. An attribute designed specifically to support back deployment should avoid these drawbacks by ensuring that:

1. The API implementation from the original library is preferred at runtime when it is available.
2. Fallback copies of the API implementation are absent from clients binaries when they would never be used.

## Proposed solution

Add a `@backDeployed(before: ...)` attribute to Swift that can be used to indicate that a copy of the function should be emitted into the client to be used at runtime when executing on an OS prior to the version identified with the `before:` argument. The attribute can be adopted by ToastKit's authors like this:

```swift
extension Toaster {
  @available(toasterOS 1.0, *)
  @backDeployed(before: toasterOS 2.0)
  public func makeBatchOfToast(_ breadSlices: [BreadSlice]) -> [Toast] { ... }
}
```

The API is now available on toasterOS 1.0 and later so clients may now reference `makeBatchOfToast(_:)` unconditionally. The compiler detects applications of `makeBatchOfToast(_:)` and generates code to automatically handle the potentially runtime unavailability of the API.

## Detailed design

The `@backDeployed` attribute may apply to functions, methods, and subscripts. Properties may also have the attribute as long as the they do not have storage. The attribute takes a comma separated list of one or more platform versions, so declarations that are available on more than one platform can be back deployed on multiple platforms with a single attribute. The following are examples of legal uses of the attribute:

```swift
extension Temperature {
  @available(toasterOS 1.0, ovenOS 1.0, *)
  @backDeployed(before: toasterOS 2.0, ovenOS 2.0)
  public var degreesFahrenheit: Double {
    return (degreesCelsius * 9 / 5) + 32
  }
}

extension Toaster {
  /// Returns whether the slot at the given index can fit a bagel.
  @available(toasterOS 1.0, *)
  @backDeployed(before: toasterOS 2.0)
  public subscript(fitsBagelsAt index: Int) -> Bool {
    get { return index < 2 }
  }
}
```

### Behavior of back deployed APIs

When the compiler encounters a call to a back deployed function, it generates and calls a thunk instead that forwards the arguments to either the library copy of the function or a fallback copy of the function. For instance, suppose the client's code looks like this:

```swift
let toast = toaster.makeBatchOfToast(slices)
```

The transformation done by the compiler would effectively result in this:

```swift
let toast = toaster.makeBatchOfToast_thunk(slices)

// Compiler generated
extension Toaster {
  func makeBatchOfToast_thunk(_ breadSlices: [BreadSlice]) -> [Toast] {
    if #available(toasterOS 2.0, *) {
      return makeBatchOfToast(breadSlices) // call the original
    } else {
      return makeBatchOfToast_fallback(breadSlices) // call local copy
    }
  }

  func makeBatchOfToast_fallback(_ breadSlices: [BreadSlice]) -> [Toast] {
    // ... copy of function body from ToastKit
  }
}
```

When the deployment target of the client app is at least toasterOS 2.0, the compiler can eliminate the branch in `makeBatchOfToast_thunk(_:)` and therefore make `makeBatchOfToast_fallback(_:)` an unused function, which reduces the unnecessary bloat that could otherwise result from referencing a back deployed API.

### Restrictions on declarations that may be back deployed

There are rules that limit which declarations may have a `@backDeployed` attribute:

* The declaration must be `public` or `@usableFromInline` since it only makes sense to offer back deployment for declarations that would be used by other modules.
* Only functions that can be invoked with static dispatch are eligible to back deploy, so back deployed instance and class methods must be `final`. The `@objc` attribute also implies dynamic dispatch and therefore is incompatible with `@backDeployed`.
* The declaration should be available earlier than the platform versions specified in `@backDeployed` (otherwise the fallback functions would never be called).
* The `@_alwaysEmitIntoClient` and `@_transparent` attributes are incompatible with `@backDeployed` because they require the function body to always be emitted into the client, defeating the purpose of `@backDeployed`.
* Declarations with `@inlinable` _may_ use `@backDeployed`. As usual with `@inlinable`, the bodies of these functions may be emitted into the client at the discretion of the optimizer. The copy of the function in the client may therefore be used even when a copy of the function is available in the library.

### Requirements for the bodies of back deployed functions

The restrictions on the bodies of back deployed functions are the same as `@inlinable` functions. The body may only reference declarations that are accessible to the client, such as `public` and `@usableFromInline` declarations. Similarly, those referenced declarations must also be at least as available the back deployed function, or `if #available` must be used to handle potential unavailability. Type checking in `@backDeployed` function bodies must ignore the library's deployment target since the body will be copied into clients with unknown deployment targets.

## Source compatibility

The introduction of this attribute to the language is an additive change and therefore doesn't affect existing Swift code.

## Effect on ABI stability

The `@backDeployed` attribute has no effect on the ABI of Swift libraries. A Swift function with and without a `@backDeployed` attribute has the same ABI; the attribute simply controls whether the compiler automatically generates additional logic in the client module. The thunk and fallback functions that are emitted into the client do have a special mangling to disambiguate them from the original function in the library, but these symbols are never referenced across separately compiled modules.

## Effect on API resilience

By itself, adding a `@backDeployed` attribute to a declaration does not affect source compatibility for clients of a library, and neither does removing the attribute. However, adding a `@backDeployed` attribute would typically be done simultaneously with expanding the availability of the declaration by lowering the `introduced:` version in the `@available` attribute. Expansion of the availability of an API is source compatible for clients, but reversing that expansion would not be.

## Alternatives considered

### Use a different argument label name

A few alternative spellings of the argument label `before:` were considered including `upTo:`, `until:`, and `implemented:`. The choice of label is significant because it influences the reader's intuitive understanding of the semantics of the attribute. The label should ideally make the directionality of the effect clear as well as the exclusivity of the OS version range. It also helps if the attribute as a whole reads fluently when expanded into an English sentence like this:

> The function is back deployed for all minimum deployment targets _before_ iOS 13.

Reviewers did not consistently agree that any of the labels that were considered successfully clarified the directionality of the effect or the exclusivity of the range but the label `before:` was ultimately deemed the clearest option.

### Use a different attribute name

One way to frame the proposed attribute is that it indicates which OS versions the function became ABI stable in. From that perspective, naming the attribute something like `@abi(introduced:)` could make sense. However, by default every public function in an SDK library is already implicitly ABI stable at the `introduced:` version of its availability so it would be reasonable to ask what distinction this attribute is making and why it is not present on every API that is ABI stable. This naming choice would obfuscate the essential effect of the attribute, requiring unfamiliar readers to read the documentation to learn that the purpose of the attribute is to extend the function's availability to earlier deployment targets.

### Extend @available

Another possible design for this feature would be to augment the existing `@available` attribute instead of introducing a new attribute. In the following example, a `backDeployBefore:` label is added to the `@available` attribute:

```swift
extension Toaster {
  @available(toasterOS, introduced: 1.0, backDeployBefore: 2.0)
  public func makeBatchOfToast(_ breadSlices: [BreadSlice]) -> [Toast]
}
```

This design has the advantage of grouping the introduction and back deployment versions together in a single attribute, which may be easier to understand for library authors who want to adopt this capability. However, there are drawbacks:

- The `@available` attribute's existing responsibilities relate to constraining the contexts in which a declaration can be used. The version in which the declaration became ABI is not an availability constraint, but rather information that the library author provides to the compiler in order to give the declaration extended availability. A client of the library does not need this information in order to understand where the API may be used. It seems wise to avoid further complicating the already complex `@available` attribute with additional responsibilities that do not relate to its core purpose.
- This design would require library authors to use the long form of `@available`, which would lead to increased verbosity for APIs that are available on many different OSes.

A variant of this alternative design would be to add a `backDeployTo:` label instead and change the meaning of the `introduced:` label to indicate the version of OS that the declaration became ABI stable:

```swift
extension Toaster {
  @available(toasterOS, backDeployTo: 1.0, introduced: 2.0)
  public func makeBatchOfToast(_ breadSlices: [BreadSlice]) -> [Toast]
}
```

This has the same drawbacks documented above and also further contradicts the principle of progressive disclosure by making it necessary to learn about back deployment as a concept in order to understand where an API declaration may be used.


## Future directions

### Back deployment for other kinds of declarations

It would also be useful to be able to back deploy the implementations of other types of declarations, such as entire enums, structs, or even protocol conformances. Exploring the feasibility of such a feature is out of scope for this proposal, but whether or not the design can accommodate being extended to other kinds of declarations is important to consider.

## Acknowledgments

Thank you to Alexis Laferriere, Ben Cohen, and Xi Ge for their help designing the feature and to Slava Pestov for his assistance with SILGen. 
