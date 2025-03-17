# Objective-C implementations in Swift

* Proposal: [SE-0436](0436-objc-implementation.md)
* Authors: [Becca Royal-Gordon](https://github.com/beccadax)
* Review Manager: [Freddy Kellison-Linn](https://github.com/Jumhyn)
* Status: **Implemented (Swift 6.1)**
* Implementation: [swiftlang/swift#73309](https://github.com/swiftlang/swift/pull/73309), [swiftlang/swift#74801](https://github.com/swiftlang/swift/pull/74801)
* Review: ([first pitch](https://forums.swift.org/t/pitch-objective-c-implementations-in-swift/61907)) ([second pitch](https://forums.swift.org/t/pitch-2-objective-c-implementations-in-swift/68090)) ([third pitch](https://forums.swift.org/t/pitch-3-objective-c-implementations-in-swift/71315)) ([review](https://forums.swift.org/t/se-0436-objective-c-implementations-in-swift/71712)) ([acceptance](https://forums.swift.org/t/accepted-se-0436-objective-c-implementations-in-swift/72053))

## Introduction

We propose an alternative to `@objc` classes where Objective-C header `@interface` declarations are implemented by Swift `extension`s marked with `@objc @implementation`. The resulting classes will be implemented in Swift, but will be indistinguishable from Objective-C classes, fully supporting Objective-C subclassing and runtime trickery.

Swift-evolution thread: [first pitch](https://forums.swift.org/t/pitch-objective-c-implementations-in-swift/61907), [second pitch](https://forums.swift.org/t/pitch-2-objective-c-implementations-in-swift/68090), [third pitch](https://forums.swift.org/t/pitch-3-objective-c-implementations-in-swift/71315)

## Motivation

Swift has always had a mechanism that allows Objective-C code to use Swift types: the `@objc` attribute. When a class is marked with `@objc` (or, more typically, inherits from an `@objc` or imported Objective-C class), Swift generates sufficient Objective-C metadata to allow it to be used through the Objective-C runtime, and prints a translated Objective-C declaration into a generated header file that can be imported into Objective-C code. The same goes for members of the class.

This feature works really well for mixed-language apps and project-internal frameworks, but it's poorly suited to exposing private and especially public APIs to Objective-C. There are three key issues:

1. To avoid circularity while building the Swift half of the module, the generated header cannot be included into other headers in the same module, which can make it difficult to use the Swift-implemented parts of the API in the Objective-C-implemented parts. Worse, some build systems install the headers for all modules and then build binaries for them out of order; generated headers can't really be used across modules in these systems.

2. Objective-C programmers expect API headers to serve as a second source of documentation on the APIs, but generated headers are disorganized, unreadable messes because Swift cannot mechanically produce the formatting that a human engineer would add to a handwritten header.

3. While `@objc` classes can be *used* from Objective-C, they are not truly Objective-C types. They still contain Swift vtables and other Swift-specific data that the Objective-C compiler and runtime don't fully understand. This limits their capabilities—for instance, Objective-C code cannot subclass an `@objc` class or reliably swizzle its methods.

Together, these issues make it very hard for frameworks with a lot of Objective-C clients to implement their functionality in Swift. If they have classes that are meant to be subclassed, it's actually impossible to fully port them to Swift, because it would break existing Objective-C subclasses. And yet the trade-offs made by `@objc` are really good for the things it's designed for, like writing custom views and view controllers in Swift app targets. We don't want to radically change the existing `@objc` feature.

Swift also quietly supports a hacky pseudo-feature that allows a different model for Objective-C interop: It will not diagnose a selector conflict if a Swift extension redeclares members already imported from Objective-C, so you can declare a method or property in a header and then implement it in a Swift extension. However, this feature has not really been designed to work properly; it doesn't check that your implementation's name and signature match the header, there's no protection against forgetting to implement a method, and you still need an `@implementation` for the class metadata itself. Nevertheless, a few projects use this and find it helpful because it avoids the issues with normal interop. Formalizing and improving this pattern seems like a promising direction for Objective-C interop.

## Proposed solution

We propose adding a new attribute, `@implementation`, which, when paired with an interop attribute like `@objc`, tells Swift that it is to implement a declaration it has imported from another language, rather than creating a new declaration and exporting it *to* that language.

Specifically, in this proposal, `@objc @implementation` allows a Swift `extension` to replace an Objective-C `@implementation` block. You write headers as normal for an Objective-C class, but instead of writing an `@implementation` in an Objective-C file, you write an `@objc @implementation extension` in a Swift file. You can even port an existing class’s implementation to Swift one category at a time without breaking backwards compatibility.

For instance, if you were adding a new class, you would start by writing a normal Objective-C header, as though you were planning to implement the class in an Objective-C .m file:

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
@objc @implementation extension MYFlippableViewController {
    ...
}
```

And the `Animation` category by writing:

```swift
@objc(Animation) @implementation extension MYFlippableViewController {
    ...
}
```

Note that there is nothing special in the header which indicates that a given `@interface` is implemented in Swift. The header can use all of the usual Swift annotations—like `NS_SWIFT_NAME`, `NS_NOESCAPE` etc.—but they simply affect how the member is imported. Swift does not even require you to implement every declared `@interface` in Swift, so you can implement some parts of a class in Objective-C and others in Swift. But if you choose to implement a particular `@interface` in Swift, each Objective-C member in that `@interface` must be matched by a Swift declaration in the extension that has the same Swift name; these special members are called "member implementations".

Specifically, member implementations must be non-`final`, not be overrides, and have an `open`, `public`, `package`, or `internal` access level. Every member implementation must match a member declared in the Objective-C header, and every member declared in the Objective-C header must have a matching member implementation. This ensures that everything declared by the header is correctly implemented without any accidental misspellings or type signature mismatches.

In addition to member implementations, an `@objc @implementation` extension can also contain three other kinds of members:

1. **Fileprivate or private non-`final` members** are helper methods (think `@IBAction`s or callback selectors). They must *not* match a member from the imported headers, but they are accessible from Objective-C by performing a selector or declaring them in a place that is not visible to Swift. (Objective-C `@implementation` blocks often declare private members like this, so it's helpful to allow them in `@objc @implementation` extensions too.)

2. **Members with an `override` modifier** override superclass members and function normally. (Again, Objective-C `@implementation` blocks often override superclass members without declaring the override in their headers, so it's helpful to allow `@objc @implementation` extensions to do the same.)

3. **Members with a `final` modifier (or `@nonobjc` on an initializer)** are Swift-only and can use Swift-only types or features. These may be Swift-only implementation details (if `internal` or `private`) or Swift-only APIs (if `public` or `package`). (This feature is necessary to support stored properties containing Swift-only types because ordinary extensions cannot declare stored properties; in theory, we could require other `final` members to be declared in a separate ordinary extension, but we also allow them in an `@objc @implementation` extension as a convenience.)

Within an `@objc @implementation` extension, `final` members are `@nonobjc` by default.

As a special exception to the usual rule, a non-category `@objc @implementation extension` can declare stored properties and other members that are normally only allowed in the main `class` body. They can be (perhaps implicitly) `@objc` or they can also be `final`; in the latter case they are only accessible from Swift. Note that `@implementation` does not have an equivalent to Objective-C's implicit `@synthesize`—you must declare a `var` explicitly for each `@property` in the header that you want to be backed by a stored property.

## Detailed design

### Custom category names

As an enabling step, we propose that using `@objc(CustomName)` on an `extension` should cause the Objective-C category created for that extension to be named `CustomName`, rather than using a category name generated by the compiler. This name should appear in both generated headers and Objective-C metadata. The compiler should enforce that there is only one extension per class/category-name combination.

`@objc(CustomName) extension` also has the effect of `@objc extension`, namely, making members of the extension `@objc` by default.

### `@implementation`

The compiler will accept a new attribute, `@implementation`, which turns a declaration that would normally be exported to another language into a declaration that implements something imported from another language. This attribute takes no arguments; it should be used alongside another attribute specifying the foreign language, such as `@objc`.

In general, `@implementation` will cause the affected declarations to be matched against imported declarations, and will emit errors if a good enough match cannot be found. It cannot necessarily be applied to all declarations that can be exported to a foreign language; for instance, `@objc @implementation` is only supported on whole extensions, not on individual members.

### `@objc @implementation extension`s

`@objc @implementation extension` causes an extension to be used as the implementation of an Objective-C `@interface` declaration for the class it extends. If the `@objc` attribute specifies a custom category name, it will implement a category with that name; otherwise it will implement the main `@interface` for the class (plus any class extensions).

```swift
@objc @implementation extension SomeClass {
    // Equivalent to `@implementation SomeClass`;
    // implements everything in `@interface SomeClass` and
    // all `@interface SomeClass ()` extensions.
}

@objc(SomeCategory) @implementation extension SomeClass {
    // Equivalent to `@implementation SomeClass (SomeCategory)`;
    // implements everything in `@interface SomeClass (SomeCategory)`.
}
```

As in any `@objc extension`, all members are implicitly `@objc` by default, and all `@objc` members are implicitly `dynamic`; unlike other `@objc extension`s, adding the `final` keyword makes the declaration *not* `@objc` by default.

As a special exception to the usual rule, an `@objc @implementation extension` which implements the main Objective-C interface of a class can declare stored properties, designated and required `init`s, and `deinit`s.

#### Rules

An `@objc @implementation extension` must:

* Extend a non-root class imported from Objective-C which does not use lightweight generics.
* If a category name is present, match a category by that name for that class (if no category name is present, the extension matches the main interface).
* Provide a member implementation (see below) for each member of the `@interface` it implements.
* Not declare conformances. (Conformances should be declared in the header if they are for Objective-C protocols, or in an ordinary extension otherwise.)
* Contain only `@objc`, `override`, `final`, or (for initializers) `@nonobjc` members. (Note that member implementations are implicitly `@objc`, as mentioned below, so this effectively means that non-`override`, non-`final`, non-`@nonobjc` members *must* be member implementations.)
* `@nonobjc` initializers must be convenience initializers, not designated or required initializers.

> **Note**: `@objc @implementation` cannot support Swift-only designated and required initializers because subclasses with additional stored properties must be able to override designated and required initializers, but `@implementation` only supports overriding of `@objc` members. The Swift-only metadata that would be used for dynamic dispatch in an ordinary `@objc` class is not present in an `@implementation` class.

### Member implementations

Any non-`override` open, public, package, or internal `@objc` member of an `@objc @implementation extension` is a “member implementation”; that is, it implements some imported Objective-C member of the class it is extending. Member implementations are special because much of the compiler completely ignores them:

* Access control denies access to member implementations in most contexts.
* Module interfaces and generated interfaces do not include member implementations.
* Objective-C generated headers do not include member implementations.

This means that calls in expressions will *always* ignore the member implementation and use the imported Objective-C member instead. In other words, even other Swift code in the same module will behave as though the member is implemented in Objective-C.

Some members cannot be implemented in an `@objc @implementation` extension because `@objc` does not support some of the features they use; see "Future Directions" for more specific discussion of this. These members will have to be moved to a separate category and implemented in Objective-C.

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

When Swift generates metadata for an `@objc @implementation extension`, it will generate metadata that matches what clang would have generated for a similar `@implementation`. That is:

* `@objc` members will only have Objective-C metadata, not Swift metadata. (`final` members may require Swift metadata.)
* If the extension is for the main class interface, it will generate complete Objective-C class metadata with an ivar for each stored property, and without setting the Swift bit or using any features incompatible with clang subclasses or categories.

## Source compatibility

These changes are additive and don't affect existing code. Replacing an Objective-C `@implementation` declaration with a Swift `@objc @implementation extension` is invisible to the library's Objective-C and Swift clients, so it should not be source-breaking unless the implementations have observable behavior differences.

Previous versions of Swift have accepted the `@objc(CustomName) extension` syntax and simply ignored the custom name, so merely adding a custom category name won't break source compatibility.

## Effect on ABI stability

All `@objc` members of an `@implementation extension`—member implementation or otherwise—have the ABI of an `@objc dynamic` member, so turning one into the other is not ABI-breaking. `@implementation extension` classes generate only Objective-C metadata, not Swift metadata, so existing Objective-C subclasses will continue to function as normal.

Because `@implementation` attributes and member implementations are not printed into module interfaces, this proposal has no direct effect on Swift ABI stability.

## Implications on adoption

`@implementation` extensions that implement categories are back-deployable to Swift 5.0 runtimes and later, and many `@implementation` extensions that implement classes are too. However, if a class's ivar layout cannot be computed at compile time, that class will require new runtime support and will not be back-deployable to old platforms.

Affected classes are ones whose stored properties contain a non-frozen enum or struct imported from another module that has library evolution enabled. (This property is transitive—if your stored properties contain a struct in your own module, but that struct has a stored property of an affected type, that also limits back deployment.) In practice, it is usually possible to work around this problem by boxing affected values in a class or existential, at the cost of some overhead.

> **Note**: Some of the required runtime changes are in the Objective-C runtime, so even a development toolchain will not be sufficient to actually run modules with affected classes. However, you can test the diagnostics and code generation by compiling with the experimental feature flag `ObjCImplementationWithResilientStorage`; OS version 99.99 will be treated as high enough to have the necessary runtime support.

## Future directions

### Extending `@objc` capabilities to extend `@objc @implementation` capabilities

`@objc @implementation` extensions cannot implement `@interface` members that cannot be created by `@objc`. The most notable limitations include:

* Factory convenience initializers (those implemented as class methods, like `+[NSString stringWithCharacters:length:]`).
* `__attribute__((objc_direct))` methods and `@property (direct)` properties.
* Members with nonstandard memory management behavior, even if it is correctly annotated.
* Members which deviate from the Objective-C error convention in certain subtle ways, such as by having the `NSError**` parameter in the wrong place.

Additionally, `@objc @implementation` cannot implement global declarations that cannot be created by `@objc`, such as: 

* Free functions, global variables, cases of `NS_TYPED_ENUM` typedefs, and other non-member Objective-C declarations.
* Global declarations imported as members of a type using `NS_SWIFT_NAME`'s import-as-member capabilities.

`@objc @implementation` heavily piggybacks on `@objc`'s code emission, so in most cases, the best approach to expanding `@implementation`'s support would be to extend `@objc` to support the feature and then make sure `@objc @implementation` supports it too.

### `@implementation` for plain C declarations

Many of the capabilities mentioned as future directions for `@objc` would also be useful for plain-C clients, including those on non-Darwin platforms. Once again, the best approach here would probably be to stabilize and extend something like `@_cdecl` to support creating these with a generated header, and then make sure `@implementation` supports this attribute too.

The compiler currently has experimental support for `@_cdecl @implementation` for global functions; it's behind a separate experimental feature flag because it's not part of this proposal.

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

@_expose(Cxx) @implementation extension CppClass {
    func swiftMethod() -> Int32 { return self.myStorage }
}
```

This would be tricker than Objective-C interop because for Objective-C interop, Swift already generates machine code thunks directly in the binary, whereas for C++ interop, Swift generates C++ source code thunks in a generated header. Swift could either compile this generated code internally, or it could emit it to a file and expect the build system to build and link it.

We believe that there wouldn't be a problem with sharing the `@implementation` attribute with this feature because `@implementation` is always paired with a language-specific attribute.

### Supporting lightweight generics

Classes using Objective-C lightweight generics have type-erased generic parameters; this imposes a lot of tricky limitations on Swift extensions of these classes. Since very few classes use lightweight generics, we have chosen to ban the combination for now. If there turns out to be a lot of demand for implementing Objective-C generic classes in Swift, we can lift the ban after we've figured out how to make the combination more usable.

### `@objc @implementation(unchecked)`

One could imagine an option that disables `@objc @implementation`'s exhaustiveness checking so that Swift implementations can use dynamic mechanisms like `+instanceMethodForSelector:` to create methods at runtime. This change would be purely additive, so we can consider it if there's demand.

### Implementation-only bridging header

This feature would work extremely well with a feature that allowed Swift to import an implementation-only bridging header alongside the umbrella header when building a public framework. This would not only give the Swift module access to internal Objective-C declarations, but also allow it to implement those declarations. However, the two features are fully orthogonal, so I’ll leave that to a different proposal.

### Improvements to private Objective-C modules

This feature would also work very well with some improvements to private Objective-C modules:

1. The Swift half of a mixed-source framework could implicitly import the private Clang module with `internal`; this would allow you to easily provide implementations for Objective-C-compatible SPI.
2. We could perhaps set up some kind of equivalence between `@_spi` and private Clang modules so that `final` Swift members could be made public.

Again, that’s something we can flesh out over time.

## Alternatives considered

### A different attribute spelling

We've chosen the proposed spelling—`@objc(CategoryName) @implementation`—because it makes `@implementation` orthogonal to the specific language being implemented. Everything Objective-C-specific about it is tied to the `@objc` attribute, and it's pretty clear how it would be expanded in the future to support other languages. Many alternatives—such as the original pitch's `@objcImplementation(CategoryName)` and suggestions like `@implementation(objc, category: CategoryName)`—do not have this property.

We chose the word "implementation" rather than "extern" because the attribute marks an implementation of something that was declared elsewhere; in most languages, "extern" works in the opposite direction, marking a declaration of something that is implemented elsewhere. Also, the name suggests a relationship to the `@implementation` keyword in Objective-C, which is appropriate since an `@objc @implementation extension` is a one-to-one drop-in replacement.

`@implementation` has a similar spelling to the compiler-internal `@_implements` attribute, but there has been little impetus to stabilize `@_implements` in the seven years since it was added, and if it ever *is* stabilized it wouldn't be unreasonable to make it a variant of `@implementation` (e.g. `@implementation(forRequirement: SomeProto.someMethod)`).

### Allow/require `@objc @implementation` extensions to declare conformances

Rather than banning `@objc @implementation` extensions from declaring conformances, we could require them to re-declare conformances listed in the header and/or allow them to add additional conformances. This would more closely align with our design decisions about members, where we allow private members and overrides because Objective-C `@implementation` allows them.

Unfortunately, every design here has at least one wart or inconsistency. There are actually four different alternatives here; let's tackle them separately:

1. **Re-declares header conformances** + **Cannot declare extra conformances**: The conformances here are pure boilerplate; they duplicate what's in the header without any opportunity to add more information. By contrast, we force the extension to re-declare members because the redeclarations *add more information* (like the body), or at least they have the opportunity to add more information. It seems wasteful to require the developer to keep two conformance lists exactly in sync.

2. **Doesn't re-declare header conformances** + **Can declare extra conformances**: The conformances behave very differently from the members. With members, you are *required* to declare what's in the header but also *allowed* to add certain kinds of extra members. Allowing a conformance list but requiring it to *not* include what's in the header is unintuitive.

3. **Re-declares header conformances** + **Can declare extra conformances**: Unlike with members—where the additional members are made textually obvious by a modifier like `private` or `final`—there would be no visual distinction between re-declared conformances and extra conformances. That's unfortunate because their visibility is very different. The extra conformances would only be visible to clients which have imported the .swiftinterface, .swiftmodule, or -Swift.h files, and clients often don't know exactly which files they are importing from a module. Having a single, combined list of things which have invisible distinctions between them would be confusing.

4. **Doesn't re-declare header conformances** + **Cannot declare extra conformances** (the design we selected): Does not map 1:1 to the behavior of `@implementation` in Objective-C (which can declare additional conformances).

Since all of these options have unappealing aspects, we have chosen the simplest one with the smallest potential for mistakes, which is banning all use of the conformance list. It is still possible to write an ordinary extension which adds conformances to an `@objc @implementation` class; these conformances will have the same visibility behavior as extra conformances would, but putting them in a separate, ordinary extension creates a visible distinction to make this obvious.  

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
@objc @implementation
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
@objc(Animation) @implementation
#endif
extension MYFlippableViewController {
    ...
}
```

This might be able to reduce code duplication for adopters who want to write cross-platform classes that only use `@implementation` on platforms which support Objective-C, and it would also mean we could remove the stored-property exception. However, it is a significantly more complicated model—there is much more we'd need to hide and a lot more scope for the `class` to have important mismatches with the `@interface`. And the reduction to code duplication would be limited because pure-Swift extension methods are non-overridable, so all methods you wanted clients to be able to override would have to be listed in the `class`. This means that in practice, mechanically generating pure-Swift code from the `@implementation`s might be a better approach.

## Acknowledgments

Doug Gregor gave a *ton* of input into this design; Allan Shortlidge reviewed much of the code; and Mike Ash provided timely help with a tricky Objective-C metadata issue. Thanks to all of them for their contributions, and thanks to all of the engineers who have provided feedback and bug reports on this feature in its experimental state.
