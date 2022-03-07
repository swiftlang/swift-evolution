# Function Back Deployment

* Proposal: [SE-NNNN](NNNN-back-deploy.md)
* Author: [Allan Shortlidge](https://github.com/tshortli)
* Implementation: [apple/swift#41271](https://github.com/apple/swift/pull/41271), [apple/swift#41348](https://github.com/apple/swift/pull/41348), [apple/swift#41416](https://github.com/apple/swift/pull/41416), [apple/swift#41612](https://github.com/apple/swift/pull/41612) as the underscored attribute `@_backDeploy` 
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

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

1. The API implemention from the original library is preferred at runtime when it is available.
2. Fallback copies of the API implementation are absent from clients binaries when they would never be used.

Swift-evolution thread: [Pitch](https://forums.swift.org/t/pitch-function-back-deployment/55769)

## Proposed solution

Add a `@backDeploy(before: ...)` attribute to Swift that can be used to indicate that a copy of the function should be emitted into the client to be used at runtime when executing on an OS prior to a specific version. The attribute can be adopted by ToastKit's authors like this:

```swift
extension Toaster {
  @available(toasterOS 1.0, *)
  @backDeploy(before: toasterOS 2.0)
  public func makeBatchOfToast(_ breadSlices: [BreadSlice]) -> [Toast] { ... }
}
```

The API is now available on toasterOS 1.0 and later so clients may now reference `makeBatchOfToast(_:)` unconditionally. The compiler detects applications of `makeBatchOfToast(_:)` and generates code to automatically handle the potentially runtime unavailability of the API.

## Detailed design

The `@backDeploy` attribute may apply to functions, methods, and subscripts. Properties may also have the attribute as long as the they do not have storage. The attribute takes a comma separated list of one or more platform versions, so declarations that are available on more than one platform can be back deployed to multiple platforms with a single attribute. The following are examples of legal uses of the attribute:

```swift
extension Temperature {
  @available(toasterOS 1.0, ovenOS 1.0, *)
  @backDeploy(before: toasterOS 2.0, ovenOS 2.0)
  public var degreesFahrenheit: Double {
    return (degreesCelcius * 9 / 5) + 32
  }
}

extension Toaster {
  /// Returns whether the slot at the given index can fit a bagel.
  @available(toasterOS 1.0, *)
  @backDeploy(before: toasterOS 2.0)
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

When the deployment target of the client app is at least toasterOS 2.0, the optimizer can eliminate the branch in `makeBatchOfToast_thunk(_:)` and make `makeBatchOfToast_fallback(_:)` an unused function.

### Restrictions on declarations that may be back deployed

There are rules that limit which declarations may have a `@backDeploy` attribute:

* The declaration must be `public` or `@usableFromInline` since it only makes sense to offer back deployment for declarations that would be used by other modules.
* Only functions that can be invoked with static dispatch are eligible to back deploy, so back deployed instance and class methods must be `final`. The `@objc` attribute also implies dynamic dispatch and therfore is incompatible with `@backDeploy`.
* Explicit availability must be specified with `@available` on the same declaration for each of the platforms that the declaration is back deployed on.
* The declaration should be available earlier than the platform versions specified in `@backDeploy` (otherwise the fallback functions would never be called).
* The `@_alwaysEmitIntoClient` and `@_transparent` attributes are incompatible with `@backDeploy` because they require that the function body to always be emitted into the client, defeating the purpose of `@backDeploy`. Declarations with `@inlinable` are also restricted from using `@backDeploy` since inlining behavior is dictated by the optimizer and use of the library function when it is available could be inconsistent as a result.

### Requirements for the bodies of back deployed functions

The restrictions on the bodies of back deployed functions are the same as `@inlinable` functions. The body may only reference declarations that are accessible to the client, such as `public` and `@usableFromInline` declarations. Similarly, those referenced declarations must also be at least as available the back deployed function, or `if #available` must be used to handle potential unavailability. Type checking in `@backDeploy` function bodies must ignore the library's deployment target since the body will be copied into clients with unknown deployment targets. 

## Source compatibility

The introduction of this attribute to the language is an additive change and therefore doesn't affect existing Swift code.

## Effect on ABI stability

The `@backDeploy` attribute has no effect on the ABI of Swift libraries. A Swift function with and without a `@backDeploy` attribute has the same ABI; the attribute simply controls whether the compiler automatically generates additional logic in the client module. The thunk and fallback functions that are emitted into the client do have a special mangling to disambiguate them from the original function in the library, but these symbols are never referenced accross separately compiled modules.

## Effect on API resilience

By itself, adding a `@backDeploy` attribute to a declaration does not affect source compatibility for clients of a library, and neither does removing the attribute. However, adding a `@backDeploy` attribute would typically be done simultaneously with expanding the availability of the declaration. Expansion of the availability of an API is source compatible for clients, but reversing that expansion would not be.

## Alternatives considered

### Extend @available

Another possible design for this feature would be to augment the existing `@available` attribute with the ability to control back deployment:

```swift
extension Toaster {
  @available(toasterOS, introduced: 1.0, backDeployBefore: 2.0)
  public func makeBatchOfToast(_ breadSlices: [BreadSlice]) -> [Toast]
}
```

This design has the advantage of grouping the introduction and back deployment versions together in a single attribute. The `@available` attribute already has quite a few responsibilities, though, and this design does not call as much attention to the fact that the declaration has important new behaviors, like exposing the function body to clients. It would also be more awkward to emit clear compiler diagnostics when there are issues related to back deployment since an individual component of an attribute would need to be identified in the messages, instead of an entire attribute.

## Future directions

### Back deployment for other kinds of declarations

It would also be useful to be able to back deploy other types of declarations, like entire enums or structs. Exploring the feasability of such a feature is out of scope for this proposal, but it does seem like the attribute should be designed to allow it to be used for this purpose.

## Acknowledgments

Thank you to Alexis Laferriere, Ben Cohen, and Xi Ge for their help designing the feature and to Slava Pestov for his assistance with SILGen. 
