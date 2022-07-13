# Warning for Retroactive Conformances of External Types in Resilient Libraries

* Proposal: [SE-0364](0364-retroactive-conformance-warning.md)
* Author: [Harlan Haskins](https://github.com/harlanhaskins)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Active Review (13 July - 27 July, 2022)**
* Implementation: [apple/swift#36068](https://github.com/apple/swift/pull/36068)

## Introduction

Many Swift libraries vend currency protocols, like Equatable, Hashable, Codable,
among others, that unlock worlds of common functionality for types that conform
to them. Sometimes, if a type from another module does not conform to a common
currency protocols, developers will declare a conformance of that type to that
protocol within their module. However, protocol conformances are globally unique
within a process in the Swift runtime, and if multiple modules declare the same
conformance, it can cause major problems for library clients and hinder the
ability to evolve libraries over time.

## Motivation

Consider a library that, for one of its core APIs, declares a conformance of
`Date` to `Identifiable`, in order to use it with an API that diffs elements
of a collection by their identity.

```swift
// Not a great implementation, but I suppose it could be useful.
extension Date: Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}
```

Now that this client has declared this conformance, if Foundation decides to
add this conformance in a later revision, this client will fail to build.

If this is an app client, that might be okay --- the breakage will be confined
to their process, and it's their responsibility to remove their conformance,
rebuild, and resubmit their app or redeploy their service.

However, if this is a library target, this conformance propagates down to every
client that imports the library. This is especially bad for frameworks that
are built with library evolution enabled, as their clients link against
binary frameworks and usually are not aware these conformances don't come from
the actual owning module.

## Proposed solution

This proposal adds a warning when library evolution is enabled that explicitly
calls out this pattern as problematic and unsupported.

```swift
/tmp/retro.swift:3:1: warning: extension declares a conformance of imported type 'Date' to imported protocol 'Identifiable'; this is not supported when library evolution is enabled
extension Date: Identifiable {
^
```

If absolutely necessary, clients can silence this warning by explicitly
module-qualifying both of the types in question, to explicitly state that they
are intentionally declaring this conformance:

```
extension Foundation.Date: Swift.Identifiable {
    // ...
}
```

## Detailed design

This warning is intentionally scoped to attempt to prevent a common mistake that
has bad consequences for ABI-stable libraries.

This warning does not trigger for conformances of external types to protocols
defined within the current module, as those conformances are safe.

## Source compatibility

This proposal is just a warning addition, and doesn't affect source
compatibility.

## Effect on ABI stability

This proposal has no effect on ABI stability.

## Effect on API resilience

This proposal has no effect on API resilience.

## Alternatives considered

#### Enabling this warning always

This pattern is technically never a good idea, since it subjects your code to
runtime breakage in the future. However, I believe the risk to individual apps
is much lower than the risk of shipping one of these retroactive conformances in
an ABI-stable framework.

#### Putting it behind a flag

This warning could very well be enabled by a flag, but there's not much
precedent in Swift for flags to disable individual warnings.
