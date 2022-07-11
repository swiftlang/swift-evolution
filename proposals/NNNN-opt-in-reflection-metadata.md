# Swift Opt-In Reflection Metadata

*   Proposal: [SE-NNNN](NNNN-opt-in-reflection-metadata.md)
*   Authors: [Max Ovtsin](https://github.com/maxovtsin)
*   Review Manager: TBD
*   Status: **Awaiting implementation**
*   Implementation: [apple/swift#34199](https://github.com/apple/swift/pull/34199)

## Introduction

This proposal seeks to increase the safety and efficiency of Swift Reflection Metadata by improving the existing mechanism and providing the opportunity to express a requirement on Reflection Metadata in APIs that consume it.  
  
Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/pitch-2-opt-in-reflection-metadata/41696)  
  

## Motivation

APIs can use Reflection Metadata differently. Some like `print`, and `dump` will still work with disabled reflection, but the output will be limited. Others, like SwiftUI rely on it and won't work correctly if the reflection metadata is missing.  
While the former can potentially benefit as well, the main focus of this proposal is on the latter.  

A developer can mistakenly turn off Reflection Metadata for a Swift module and won't be warned at compile-time if APIs that consume reflection are used by that module. An app with such a module won't behave as expected at runtime which may be challenging to notice and track down such bugs back to Reflection. For instance, SwiftUI implementation uses reflection metadata from user modules to trigger re-rendering of the view hierarchy when a state has changed. If for some reason a user module was compiled with metadata generation disabled, changing the state won't trigger that behaviour and will cause inconsistency between state and representation which will make such API less safe since it becomes a runtime issue rather than a compile-time one.  
  
On the other hand, excessive Reflection metadata may be preserved in a binary even if not used, because there is currently no way to statically determine its usage. There was an attempt to limit the amount of unused reflection metadata by improving its stripability by the Dead Code Elimination LLVM pass, but in many cases, it’s still preserved in the binary because it’s referenced by Full Type Metadata which prevents Reflection Metadata from stripping.  
  
Introducing a static compilation check potentially can help to solve both of mentioned issues by adding to the language a way to express the requirement to have Reflection metadata at runtime.  
  

## Proposed solution

Teaching the Type-checker to ensure Reflection metadata is preserved in a binary if reflection-consuming APIs are used, will help to move the issue from runtime to compile time.  
  
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

### Conditional cast (`as? Reflectable`)
We also propose to allow a conditional cast to the `Reflectable` marker protocol, which would succeed only if Reflection Metadata related to a type is available at runtime. This would allow developers to explicitly check if reflection metadata is available and based on that fact branch the code accordingly.

```swift
public  func consume(_ t:  Any) {
    if  let _t = t as? Reflectable {
        // Use Mirror API to extract Reflection Metadata
    }  else  {
        // Back to default implementation
    }
}
```

### Behaviour change for Swift 6
For Swift 6, we propose to enable Opt-in behaviour by default, to make the user experience consistent and safe.  To achieve that we will need to deprecate the compiler's options that can lead to missing reflection - `-reflection-metadata-for-debugger-only` and `-disable-reflection-metadata`. Starting with Swift 6, these arguments will be ignored in favour of the default opt-in mode.

## Detailed design

Since Reflection symbols might be used by LLDB, there will be difference in emitted Reflection symbols across Debug and Release modes.  
**Release mode**: if `-O`, `-Osize`, `-Ospeed` passed.  
**Debug**: - if `-Onone` passed or if not set.  
  
One more level of reflection metadata will be introduced in addition to the existing ones:    

1.  Reflection Disabled (`-disable-reflection-metadata`)

-   Do not emit reflection in Release and Debug modes.
-   If there is a type in a module conforming to `Reflectable`, the compiler will emit an error.

2.  Enabled for the debugger support (`-reflection-metadata-for-debugger-only`)

-   Emit Reflection metadata for all types in Debug mode while emitting nothing in Release modes.
-   If there is a type in a module conforming to `Reflectable`, the compiler will emit an error (even if in Debug mode the metadata is actually emitted).

3.  Opt-in enabled (`-enable-opt-in-reflection-metadata`)

-   In Release mode, emit only for types that conform to `Reflectable`.
-   In Debug mode emit reflection in full.

4.  Fully enabled (current default level)

-   Emit reflection metadata for all types in Release and Debug modes.

Introducing a new flag to control the feature will allow us to safely roll it out and avoid breakages of the existing code. For those modules that get compiled with fully enabled metadata, nothing will change (all symbols will stay). For modules that have the metadata disabled, but are consumers of reflectable API, the compiler will emit the error enforcing the guarantee.
  

## Source compatibility

The change won’t break source compatibility in versions prior to Swift 6, because of the gating by the new flag. If as proposed, it’s enabled by default in Swift 6, the code with types that has not been audited to conform to the `Reflectable` protocol will fail to compile if used with APIs that consume the reflection metadata.  


## Effect on ABI stability

`Reflectable` is a marker protocol, which doesn't have a runtime representation, has no requirements and doesn't affect ABI.  
  
  

## Effect on API resilience

This proposal has no effect on API resilience.  
  
  

## Alternatives considered

Dead Code Elimination and linker optimisations were also considered as a way to reduce the amount of present Reflection metadata in release builds. The optimiser could use a conformance to a `Reflectable` protocol as a hint about what reflection metadata should be preserved. However, turned out it was quite challenging to statically determine all usages of Reflection metadata even with hints.  
  
It was also considered to use an attribute `@reflectable` on nominal type declaration to express the requirement to have reflection metadata, however, a lot of logic had to be re-implemented outside of type-checker to ensure all guarantees are fulfilled.