# Objective-C implementations in Swift

* Proposal: [SE-NNNN](NNNN-objc-implementation.md)
* Authors: [Becca Royal-Gordon](https://github.com/beccadax)
* Review Manager: TBD
* Status: **Awaiting implementation** (but only of resilience support)
* Implementation: In main and release/6.0, behind the `ObjCImplementation` experimental feature flag
* Upcoming Feature Flag: `ObjCImplementation`

## Introduction

We propose an alternative to `@objc` classes where Objective-C header `@interface` declarations are implemented by Swift `extension`s. The resulting classes will be implemented in Swift, but will be indistinguishable from Objective-C classes, fully supporting Objective-C subclassing and runtime trickery.

Swift-evolution thread: [first pitch](https://forums.swift.org/t/pitch-objective-c-implementations-in-swift/61907), (this one)

## Motivation

Swift has always had a mechanism that allows Objective-C code to use Swift types: The `@objc` attribute. When a class is marked with `@objc` (or, more typically, inherits from an `@objc` or imported Objective-C class), Swift generates sufficient Objective-C metadata to allow it to be used through the Objective-C runtime, and prints a translated Objective-C declaration into a generated header file that can be imported into Objective-C code. The same goes for members of the class.

This feature works really well for mixed-language apps and project-internal frameworks, but it's poorly suited to exposing private and especially public APIs to Objective-C. There are three key issues:

1. To avoid circularity while building the Swift half of the module, the generated header cannot be included into other headers in the same module, which can make it difficult to use the Swift-implemented parts of the API in the Objective-C-implemented parts. Worse, some build systems install the headers for all modules and then build binaries for them out of order; generated headers can't really be used across modules in these systems.

2. Objective-C programmers expect API headers to serve as a second source of documentation on the APIs, but generated headers are disorganized, unreadable messes because Swift cannot mechanically produce the formatting that a human engineer would add to a handwritten header.

3. While `@objc` classes can be *used* from Objective-C, they are not truly Objective-C types. They still contain Swift vtables and other Swift-specific data that the Objective-C compiler and runtime don't fully understand. This limits their capabilities—for instance, Objective-C code cannot subclass an `@objc` class or reliably swizzle its methods.

Together, these issues make it very hard for frameworks with a lot of Objective-C clients to implement their functionality in Swift. If they have classes that are meant to be subclassed, it's actually impossible to fully port them to Swift, because it would break existing Objective-C subclasses. And yet the trade-offs made by `@objc` are really good for the things it's designed for, like writing custom views and view controllers in Swift app targets. We don't want to radically change the existing `@objc` feature.

Swift also quietly supports a hacky pseudo-feature that allows a different model for Objective-C interop: It will not diagnose a selector conflict if a Swift extension redeclares members already imported from Objective-C, so you can declare a method or property in a header and then implement it in a Swift extension. However, this feature has not really been designed to work properly; it doesn't check that your implementation's name and signature match the header, there's no protection against forgetting to implement a method, and you still need an `@implementation` for the class metadata itself. Nevertheless, a few projects use this and find it helpful because it avoids the issues with normal interop. Formalizing and improving this pattern seems like a promising direction for Objective-C interop.

## Proposed solution

We propose adding a new attribute, `@implementation`, which allows a Swift `extension` to replace an Objective-C `@implementation` block. You write headers as normal for an Objective-C class, but instead of writing an `@implementation` in an Objective-C file, you write an `@implementation extension` in a Swift file. You can even port an existing class’s implementation to Swift one category at a time without breaking backwards compatibility.

Specifically, if you were adding a new class, you would start by writing a normal Objective-C header, as though you were planning to implement the class in an Objective-C .m file:

```objc
#import <UIKit/UIKit.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@interface MYFlippableViewController : UIViewController

@property (strong) UIViewController *frontViewController;
@property (strong) UIViewController *backViewController;
@property (assign,getter=isShowingFront) BOOL showingFront;

- (instancetype)initWithFrontViewController:(UIViewController *)front backViewController:(UIVIewController *)back;

@end

@interface MYFlippableViewController (Animation)

- (void)setShowingFront:(BOOL)isShowingFront animated:(BOOL)animated NS_SWIFT_NAME(setIsShowingFront(_:animated:));
- (void)setFrontViewController:(UIViewController *)front animated:(BOOL)animated;
- (void)setBackViewController:(UIViewController *)back animated:(BOOL)animated;

@end

@interface MYFlippableViewController (Actions)

- (IBAction)flip:(id)sender;

@end

NS_HEADER_AUDIT_END(nullability, sendability)
```

And you would arrange for Swift to import it through an umbrella or bridging header. You would then write an `extension` for each `@interface` you wish to implement in Swift. For example, you could implement the main `@interface` (plus any visible class extensions) in Swift by writing:

```swift
@implementation extension MYFlippableViewController {
    ...
}
```

And the `Animation` category by writing:

```swift
@implementation(Animation) extension MYFlippableViewController {
    ...
}
```

Note that there is nothing special in the header which indicates that a given `@interface` is implemented in Swift. The header can use all of the usual Swift annotations—like `NS_SWIFT_NAME`, `NS_NOESCAPE` etc.—but they simply affect how the member is imported. Swift does not even require you to implement every declared `@interface` in Swift, so you can implement some parts of a class in Objective-C and others in Swift. But if you choose to implement a particular `@interface` in Swift, each Objective-C member in that `@interface` must be matched by a Swift declaration in the extension that has the same Swift name; these special members are called "member implementations".

An `@implementation extension` can contain four kinds of members:

1. **Open, public, package, or internal `@objc` members** must be member implementations. Swift will give you an error if they don't match a member from the imported headers, so it will diagnose typos and mismatched Swift names.
2. **Fileprivate or private `@objc` members** are helper methods (think `@IBAction`s or callback selectors). They must *not* match a member from the imported headers, but they are accessible from Objective-C by performing a selector or declaring them in a place that is not visible to Swift.
3. **Members with a `final` modifier (or `@nonobjc` on an initializer)** are Swift-only and can use Swift-only types or features. These may be Swift-only implementation details (if `internal` or `private`) or Swift-only APIs (if `public` or `package`).
4. **Members with an `override` modifier** override superclass members and function normally.

Within an `@implementation` extension, all members are `@objc` unless they are marked `final` or `@nonobjc`, and all `@objc` members are `dynamic`.

As a special exception to the usual rule, a non-category `@implementation extension` can declare stored properties and other members that are normally only allowed in the main `class` body. They can be (perhaps implicitly) `@objc` or they can also be `final`; in the latter case they are only accessible from Swift. Note that `@implementation` does not have an equivalent to Objective-C's implicit `@synthesize`—you must declare a `var` explicitly for each `@property` in the header that you want to be backed by a stored property.

## Detailed design

### `@implementation extension`s

The compiler will accept a new attribute, `@implementation`, on `extension`s. This attribute can optionally be followed by a parenthesized identifier. If this identifier is present, the extension matches an Objective-C category with that name. If it is absent, it matches the main Objective-C interface and all Objective-C class extensions.

```swift
@implementation extension SomeClass {
    // Equivalent to `@implementation SomeClass`;
    // implements everything in `@interface SomeClass` and
    // all `@interface SomeClass ()` extensions.
}

@implementation(SomeCategory) extension SomeClass {
    // Equivalent to `@implementation SomeClass (SomeCategory)`;
    // implements everything in `@interface SomeClass (SomeCategory)`.
}
```

All non-`final`, non-`@nonobjc` members are implicitly `@objc`, and all `@objc` members are implicitly `dynamic`. As a special exception to the usual rule, an extension which implements the main Objective-C interface of a class can declare stored properties, designated and required `init`s, and `deinit`s.

#### Rules

An `@implementation extension` must:

* Extend a non-root class imported from Objective-C which does not use lightweight generics.
* If a category name is present, have imported a category by that name for that class (if no category name is present, the extension matches the main interface).
* Be the only extension on that class with that `@implementation` category name (or lack of category name).
* Not declare conformances. (Conformances should be declared in the header if they are for Objective-C protocols, or in an ordinary extension otherwise.)
* Provide a member implementation (see below) for each member of the `@interface` it implements.
* Contain only `@objc`, `override`, `final`, or (for initializers) `@nonobjc` members. (Note that member implementations are implicitly `@objc`, as mentioned below, so this effectively means that non-`override`, non-`final`, non-`@nonobjc` members *must* be member implementations.)
* `@nonobjc` initializers must be convenience initializers, not designated or required initializers.

> **Note**: `@implementation` cannot support Swift-only designated and required initializers because subclasses with additional stored properties must be able to override designated and required initializers, but `@implementation` only supports overriding of `@objc` members. The Swift-only metadata that would be used for dynamic dispatch in an ordinary `@objc` class is not present in an `@implementation` class.

### Member implementations

Any non-`override` open, public, package, or internal `@objc` member of an `@implementation extension` is a “member implementation”; that is, it implements some imported Objective-C member of the class it is extending. Member implementations are special because much of the compiler completely ignores them:

* Access control denies access to member implementations in most contexts.
* Module interfaces and generated interfaces do not include member implementations.
* Objective-C generated headers do not include member implementations.

This means that calls in expressions will *always* ignore the member implementation and use the imported Objective-C member instead. In other words, even other Swift code in the same module will behave as though the member is implemented in Objective-C.

If a member implementation doesn't have an `@objc` attribute, one will be synthesized with the appropriate selector.

#### Rules

A member implementation must:

* Have the same Swift name as the member it implements.
* Have the same selector as the member it implements.
* Have the same foreign error convention and foreign async convention as the member it implements.
* Not have other traits, like an overload signature, `@nonobjc`/`final` attribute, `class` modifier, or mutability, which is incompatible with the member it implements.
* Not have `@_spi` attributes (they would be pointless since the visibility of the imported Objective-C attribute is what will make the member usable or not).

Both the Swift name and the Objective-C selector of a member implementation must match the corresponding Objective-C declaration; Swift will diagnose an error if one matches but the other doesn't. This checking respects both the `@objc(custom:selector:)` in Swift implementations and the Swift name (`NS_SWIFT_NAME(custom(_:name:))`) attribute in Objective-C headers.

Member implementations must have an overload signature that closely matches the Objective-C declaration’s. However, types that are non-optional in the Objective-C declaration may be implicitly unwrapped optionals in the member implementation if this is ABI-compatible; this is because Objective-C does not prevent clients from passing `nil` or implementations from returning `nil` when `nonnull` is used, and member implementations may need to implement backwards compatibility logic for this situation.

### Objective-C metadata generation

When Swift generates metadata for an `@implementation extension`, it will generate metadata that matches what clang would have generated for a similar `@implementation`. That is:

* `@objc` members will only have Objective-C metadata, not Swift metadata. (`final` members may require Swift metadata.)
* If the extension is for the main class interface, it will generate complete Objective-C class metadata with an ivar for each Objective-C-compatible stored property, and without setting the Swift bit or using any features incompatible with clang subclasses or categories.

## Source compatibility

This change is additive and doesn't affect existing code. Replacing an Objective-C `@implementation` declaration with a Swift `@implementation extension` is invisible to the library's Objective-C and Swift clients, so it should not be source-breaking unless the implementations have observable behavior differences.

## Effect on ABI stability

All `@objc` members of an `@implementation extension`—member implementation or otherwise—have the ABI of an `@objc dynamic` member, so turning one into the other is not ABI-breaking. `@implementation extension` classes generate only Objective-C metadata, not Swift metadata, so existing Objective-C subclasses will continue to function as normal.

Because `@implementation` attributes and member implementations are not printed into module interfaces, this proposal has no direct effect on Swift ABI stability.

## Implications on adoption

The exact backwards deployment constraints for this feature are not yet certain.

> **Note**: Support for resilient value-typed stored properties (which have variable size, and thus require the class to modify its ivar layout before it is realized) is currently under development. At this point we're certain that they can be supported and we think it's likely they can be back-deployed to all platforms with Swift in the OS, but the exact implementation is still being developed and it's possible there will be tighter back-deployment limitations.

## Future directions

### Extending `@objc` capabilities to extend `@implementation` capabilities

`@implementation` cannot create declarations that aren't supported by `@objc`. The most notable limitations include:

* Free functions, global variables, cases of `NS_TYPED_ENUM` typedefs, and other non-member Objective-C declarations.
* Global declarations imported as members of a type using `NS_SWIFT_NAME`'s import-as-member capabilities.
* Factory convenience initializers (those implemented as class methods, like `+[NSString stringWithCharacters:length:]`).
* `__attribute__((objc_direct))` methods and `@property (direct)` properties.
* Members with nonstandard memory management behavior, even if it is correctly annotated.
* Members which deviate from the Objective-C error convention in certain subtle ways, such as by having the `NSError**` parameter in the wrong place.

`@implementation` heavily piggybacks on `@objc`'s code emission, so in most cases, the best approach to expanding `@implementation`'s support would be to extend `@objc` to support the feature and then make sure `@implementation` supports it too.

### `@implementation` for plain C declarations

Many of the capabilities mentioned as future directions for `@objc` would also be useful for plain-C clients, including those on non-Darwin platforms. Once again, the best approach here would probably be to stabilize and extend something like `@_cdecl` to support creating these with a generated header, and then make sure `@implementation` supports this attribute too.

The compiler currently has experimental support for `@implementation @_cdecl` for global functions; it's behind a separate experimental feature flag because it's not part of this proposal.

### `@implementation` for C++ declarations

One could similarly imagine a C++ version of this feature:

```cpp
// C++ header file

class CppClass {
private:
    int myStorage = 0;
public:
    int someMethod() { ... }
    int swiftMethod();
};
```

```swift
// Swift implementation file

@implementation extension CppClass {
    func swiftMethod() -> Int32 { return self.myStorage }
}
```

This would be tricker than Objective-C interop because for Objective-C interop, Swift already generates machine code thunks directly in the binary, whereas for C++ interop, Swift generates C++ source code thunks in a generated header. Swift could either compile this generated code internally, or it could emit it to a file and expect the build system to build and link it.

We believe that there wouldn't be a problem with sharing the `@implementation` attribute with this feature; Swift could detect whether a given extension is extending an Objective-C class or a C++ class and change its behavior to match.

### Supporting lightweight generics

Objective-C's "lightweight generics" behave in rather janky ways in Swift extensions, so we have banned them in this initial document. If there’s demand for implementing Objective-C generic classes in Swift, we may want to extend this feature to support them.

### Implementation-only bridging header

This feature would work extremely well with a feature that allowed Swift to import an implementation-only bridging header alongside the umbrella header when building a public framework. This would not only give the Swift module access to internal Objective-C declarations, but also allow it to implement those declarations. However, the two features are fully orthogonal, so I’ll leave that to a different proposal.

### Improvements to private Objective-C modules

This feature would also work very well with some improvements to private Objective-C modules:

1. The Swift half of a mixed-source framework could implicitly import the private Clang module with `internal`; this would allow you to easily provide implementations for Objective-C-compatible SPI.
2. We could perhaps set up some kind of equivalence between `@_spi` and private Clang modules so that `final` Swift members could be made public.

Again, that’s something we can flesh out over time.


## Alternatives considered

### A different attribute spelling

Previous drafts of this proposal used the name `@objcImplementation`. We shortened that to `@implementation` to allow us to use the same attribute for the C and C++ future directions described above.

We chose the word "implementation" rather than "extern" because the attribute marks an implementation of something that was declared elsewhere; in most languages, "extern" works in the opposite direction, marking a declaration of something that is implemented elsewhere. Also, the name suggests a relationship to the `@implementation` keyword in Objective-C, which is appropriate since an `@implementation extension` is a one-to-one drop-in replacement.

`@implementation` has a similar spelling to the compiler-internal `@_implements` attribute, but there has been little impetus to stabilize `@_implements` in the seven years since it was added, and if it ever *is* stabilized it wouldn't be unreasonable to make it a variant of `@implementation` (e.g. `@implementation(forRequirement: SomeProto.someMethod)`).

### `@implementation class`

We considered using a `class` declaration, not an `extension`, to implement the main body of a class:

```swift
// Header as above

#if canImport(UIKit)
import UIKit
#else
import SwiftUIKitClone    // hypothetical pure-Swift UIKit for non-Darwin platforms
#endif

#if OBJC
@implementation
#endif
class MYFlippableViewController: UIViewController {
    var frontViewController: UIViewController {
        didSet { ... }
    }
    var backViewController: UIViewController {
        didSet { ... }
    }
    var isShowingFront: Bool {
        didSet { ... }
    }
    
    init(frontViewController: UIViewController, backViewController: UIViewController) {
        ...
    }
}

#if OBJC
@implementation(Animation)
#endif
extension MYFlippableViewController {
    ...
}
```

This might be able to reduce code duplication for adopters who want to write cross-platform classes that only use `@implementation` on platforms which support Objective-C, and it would also mean we could remove the stored-property exception. However, it is a significantly more complicated model—there is much more we'd need to hide and a lot more scope for the `class` to have important mismatches with the `@interface`. And the reduction to code duplication would be limited because pure-Swift extension methods are non-overridable, so all methods you wanted clients to be able to override would have to be listed in the `class`. This means that in practice, mechanically generating pure-Swift code from the `@implementation`s might be a better approach.

## Acknowledgments

Doug Gregor gave a *ton* of input into this design.
