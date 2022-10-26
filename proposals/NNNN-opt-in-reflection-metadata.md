
# Swift Opt-In Reflection Metadata

*   Proposal: [SE-NNNN](NNNN-opt-in-reflection-metadata.md)
*   Authors: [Max Ovtsin](https://github.com/maxovtsin)
*   Review Manager: TBD
*   Status: **Awaiting implementation**
*   Implementation: [apple/swift#34199](https://github.com/apple/swift/pull/34199)

## Introduction

This proposal seeks to increase the safety, efficiency and privacy of Swift Reflection Metadata by improving the existing mechanism and providing the opportunity to express a requirement on Reflection Metadata in APIs that consume it. 
  
Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/pitch-3-opt-in-reflection-metadata/58852)


## Motivation

There are two kinds of Swift metadata emitted be the compiler:

1. Core Metadata (type metadata record, nominal type descriptor, etc).
2. Reflection metadata (reflection metadata field descriptor).

Core metadata must constantly be emitted and may only be stripped if provenly not used. (This metadata isn't affected by this proposal)
Reflection metadata contains optional information about declarations' fields - their names and references to their types. This metadata isn't used by the language's runtime features, and the emission may be skipped if such types aren't passed to reflection-consuming APIs.

APIs can use Reflection Metadata differently. Some like `print`, and `dump` will still work with disabled reflection, but the output will be limited. Others, like SwiftUI, rely on it and won't work correctly if the reflection metadata is missing.
While the former can benefit as well, the main focus of this proposal is on the latter.

A developer can mistakenly turn off Reflection Metadata for a Swift module and won't be warned at compile-time if APIs that consume reflection are used by that module. An app with such a module won't behave as expected at runtime which may be challenging to notice and track down such bugs back to Reflection. For instance, SwiftUI implementation uses reflection metadata from user modules to trigger the re-rendering of the view hierarchy when a state has changed. If for some reason a user module was compiled with metadata generation disabled, changing the state won't trigger that behavior and will cause inconsistency between state and representation which will make such API less safe since it becomes a runtime issue rather than a compile-time one.

On the other hand, excessive Reflection metadata may be preserved in a binary even if not used, because there is currently no way to statically determine its usage. There was an attempt to limit the amount of unused reflection metadata by improving its stripability by the Dead Code Elimination LLVM pass, but in many cases, it’s still preserved in the binary because it’s referenced by Full Type Metadata which prevents Reflection Metadata from stripping.  This unnecessarily increases the binary size and may affect privacy by storing more information about the code's semantics in a binary, which might be used for reverse-engineering.

Introducing a static compilation check can help to solve both of mentioned issues by adding to the language a way to express the requirement to have Reflection metadata at runtime.


## Proposed solution

Teaching the Type-checker and IRGen to ensure Reflection metadata is preserved in a binary if reflection-consuming APIs are used, will help to move the issue from runtime to compile time.

To achieve that, a new marker protocol `Reflectable` will be introduced. Firstly, APIs developers will gain an opportunity to express a dependency on Reflection Metadata through a generic requirement of their functions, which will make such APIs safer. Secondly, during IRGen, the compiler will be able to selectively emit Reflection symbols for the types that explicitly conform to the `Reflectable` protocol, which will reduce the overhead from reflection symbols for cases when reflection is emitted but not consumed.

### Case Study 1:

SwiftUI Framework:
```swift
protocol SwiftUI.View: Reflectable {}  
class NSHostingView<Content> where Content : View {  
    init(rootView: Content) { ... }  
}
```
User module:  
```swift
import SwiftUI  
  
struct SomeModel {}  
  
struct SomeView: SwiftUI.View {  
    var body: some View {          
        Text("Hello, World!")  
            .frame(...)      
    }  
}  
  
window.contentView = NSHostingView(rootView: SomeView())
```
Reflection metadata for `SomeView` will be emitted because it implicitly conforms to `Reflectable` protocol, while for `SomeModel` Reflection metadata won't be emitted. If the user module gets compiled with the reflection metadata disabled, the compiler will emit an error.
  

### Case Study 2:

Framework:
```swift
public func foo<T: Reflectable>(_ t: T) { ... }
```
User module:  
```swift
struct Bar: Reflectable {}  
foo(Bar())
```
Reflection metadata for `Bar` will be emitted because it explicitly conforms to Reflectable protocol. Without conformance to Reflectable, an instance of type Bar can't be used on function `foo`. If the user module gets compiled with the reflection metadata disabled, the compiler will emit an error.


### Conditional and Force casts (`as? Reflectable`, `as! Reflectable`, `is Reflectable`)

We also propose to allow conditional and force casts to the `Reflectable` protocol, which would succeed only if Reflection Metadata related to a type is available at runtime. This would allow developers to explicitly check if reflection metadata is present and based on that fact branch the code accordingly.

```swift
public func conditionalUse<T>(_ t:  T) {
    if let _t = t as? Reflectable { // Consume Reflection metadata
    } else { // Back to default implementation }
}

public func forceUse<T>(_ t:  T) {
    debugPrint(t as! Reflectable) // Will crash if reflection metadata isn't available
}

public func testIsReflectable<T>(_ t:  T) -> Bool {
    return t is Reflectable // returns True if reflection is available
}
```

### Behavior change for Swift 6
Starting with Swift 6, we propose to enable Opt-In mode by default, to make the user experience consistent and safe. However, if full reflection isn't enabled with a new flag (`-enable-full-reflection-metadata`), the emission of reflection metadata will be skipped for all types that don't conform to the `Reflectable` protocol. This may cause changes in the behavior of the code that wasn't audited to conform to Reflectable and uses reflection-consuming APIs.

For instance, stdlib's APIs like `dump`, `debugPrint`, `String(describing:)` will be returning limited output.
Library authors will have to prepare their APIs for Swift 6 and introduce generic requirements on `Reflectable` in their APIs.

We also propose to deprecate the compiler's options that can lead to missing reflection - `-reflection-metadata-for-debugger-only` and `-disable-reflection-metadata` and starting with Swift 6, ignore these arguments in favor of the default opt-in mode.


### Stdlib behavior changes
In Swift `Mirror(reflecting:)` is the only official way to access Reflection metadata, all other APIs are using it under the hood. We intentionally do not propose adding a Reflectable constraint on Mirror type, because it would impose restrictions on those developers who still don't want to require it. If the presence of reflection metadata is mandatory, the requirement on Reflectable protocol should be expressed in the signatures of calling functions.


## Detailed design

Since Reflection symbols might be used by the debugger, there will be difference in emitted Reflection symbols across Debug and Release modes.
**Release mode**: if `-O`, `-Osize`, `-Ospeed` passed.
**Debug**: - if `-Onone` passed or if not set.

**Changes in flags**
To handle behavior change between Swift pre-6 and 6, we can introduce a new upcoming feature, which will allow to enable Opt-In mode explicitly for pre-6 Swift with `-enable-upcoming-feature OptInReflection` and will set this mode by default in Swift 6.

A new flag `-enable-full-reflection-metadata` will also have to be introduced to allow developers to enable reflection in full if they desire in Swift 6 and later.

For Swift 6, flags `-disable-reflection-metadata` and `-emit-reflection-for-debugger` will be a no-op, to ensure the reflection metadata is always available when needed.

1.  Reflection Disabled (`-disable-reflection-metadata` and `-reflection-metadata-for-debugger-only`)
- Do not emit reflection in Release and Debug modes for Swift pre-6.
- A no-op in Swift 6 and later.
- If there is a type in a module conforming to `Reflectable`, the compiler will emit an error.

2.  Opt-In Reflection (`-enable-upcoming-feature OptInReflection`)
- In Release mode, emit only for types that conform to `Reflectable`.
- In Debug mode emit reflection in full.
- For Swift pre-6 will require an explicit flag, for Swift 6 will be enabled by default.

3.  Fully enabled (`-enable-full-reflection-metadata`)
- Emit reflection metadata for all types in Release and Debug modes.
- Conformance to Reflectable will be synthesized for all types to allow usage of reflection-consuming APIs.
- Current default level for Swift pre-6.

Introducing a new flag to control the feature will allow us to safely roll it out and avoid breakages of the existing code. For those modules that get compiled with fully enabled metadata, nothing will change (all symbols will stay present). For modules that have the metadata disabled, but are consumers of reflectable API, the compiler will emit the error enforcing the guarantee.

### Casts implementation
Casting might be a good way to improve the feature's ergonomics because currently there is no way to check if reflection is available at runtime. (`Mirror.children.count` doesn't really help because it doesn't distinguish between the absence of reflection metadata and the absence of fields on a type)

To implement this feature, we propose to introduce a new runtime function `swift_reflectableCast`, and emit a call to it instead of `swift_dynamicCast`during IRGen if Reflectable is a target type.

Because of the fact that the compiler emits a call to that function at compile-time, all casts must be statically visible. All other cases like implicit conversion to `Reflectable` must be banned. This could be done at CSSimplify, when a new conversion constraint is introduced between a type variable and `Reflectable` type, the compiler will emit an error.

```swift
func cast<T, U>(_ x: U) -> T {
    return x as! T
}
let a = cast(1) as Reflectable // expression can't be implicitly converted to Reflectable; use 'as? Reflectable' or 'as! Reflectable' instead
let b: Reflectable = cast(1) // expression can't be implicitly converted to Reflectable; use 'as? Reflectable' or 'as! Reflectable' instead
```
Some diagnostics and optimizations will also have to be disabled even if conformance is statically visible to the compiler because all casts will have to go through the runtime call.

**Availability checks**
Since reflectable casting will require a new runtime function, it should be gated by availability checks. If a deployment target is lower than supported, an error will be emitted.


## Source compatibility

The change won’t break source compatibility in versions prior to Swift 6, because of the gating by the new flag. If as proposed, it’s enabled by default in Swift 6, the code with types that has not been audited to conform to the `Reflectable` protocol will fail to compile if used with APIs that consume the reflection metadata.  


## Effect on ABI stability

`Reflectable` is a marker protocol, which doesn't have a runtime representation, has no requirements and doesn't affect ABI.

## Effect on API resilience

This proposal has no effect on API resilience.  

## Alternatives considered

Dead Code Elimination and linker optimisations were also considered as a way to reduce the amount of present Reflection metadata in release builds. The optimiser could use a conformance to a `Reflectable` protocol as a hint about what reflection metadata should be preserved. However, turned out it was quite challenging to statically determine all usages of Reflection metadata even with hints.  

It was also considered to use an attribute `@reflectable` on nominal type declaration to express the requirement to have reflection metadata, however, a lot of logic had to be re-implemented outside of type-checker to ensure all guarantees are fulfilled.