# Enable Macros to Grant `self` Access for Property Initializers

* Proposal: [SE-0539](0539-self-access-for-property-initializers.md)
* Authors: [Nils Grabenhorst](https://github.com/nilsgrabenhorst)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Returned for revision**
* Implementation: [swiftlang/swift#89757](https://github.com/swiftlang/swift/pull/89757)
* Review: ([pitch](https://forums.swift.org/t/pitch-lazy-accessor-macros/87515)) ([review](https://forums.swift.org/t/se-0539-enable-macros-to-grant-self-access-for-property-initializers/88713)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0539-enable-macros-to-grant-self-access-for-property-initializers/89155))

## Summary of changes

Adds an optional `initialization: selfAvailable` parameter for `accessor` macro role declarations. This parameter declares that the macro moves a property initializer expression to a new context, where access to `self` and instance members is available.

## Motivation

Swift allows for lazy property initialization with the `lazy` keyword, which has been available long before macros were introduced. This is useful for properties where

- initialization is expensive and should be avoided unless actually needed
- initialization depends on values that become available _after_ initialization of the enclosing type, including access to `self`

Here is a rough description of the transformations applied to a `lazy var foo: T = initExpr()` by the compiler:

- a private backing var of type `T?` is added in the same scope, initial value is `nil`
- the original property is converted into a computed property.
- in the `get` accessor, the initializer is used if the backing var is `nil`

The conversion looks approximately like this:
```swift
private __foo: T? = nil

var foo: T {
    get {
        if let value = __foo {
            return value
        }
        let newValue = initExpr()
        __foo = newValue
        return newValue
    }
    set {
        __foo = newValue
    }
}
```

The initializer expression is type-checked in the original context as if it was already moved into the getter. This feels natural and convenient:

```swift
struct Earth {
    let mice = 21
    
    let noGood = mice * 2
    //           ^ 🛑 cannot use instance member 'mice' within property initializer; property initializers run before 'self' is available
    
    // ✅ initializer expression has access to `self`!
    lazy var theAnswer = mice * 2
}
```

We can write an accessor macro that performs a similar transformation. Unfortunately, the compiler currently assumes that the property initializer is eagerly evaluated, regardless of the actual context after macro expansion. Therefore, we get a compiler error if we need `self` access:

```swift
struct Earth {
    let mice = 21
    
    @Lazy
    var theAnswer = mice * 2
    //              ^ 🛑 cannot use instance member 'mice' within property initializer; property initializers run before 'self' is available
}
```
The error is unnecessarily limiting, because `@Lazy` moves the initializer into a `get` accessor, where `self` access is allowed. 

There is another [example](https://forums.swift.org/t/pitch-lazy-accessor-macros/87515#p-399664-concrete-example-2) in the original pitch, which shows how the proposed change could enable access to SwiftUI environment values when initializing `Observable` objects.

## Proposed solution

Add an optional `initialization:` parameter to the accessor macro role declaration. Valid arguments are `selfAvailable` or `selfUnavailable`. A macro author uses `selfAvailable` to declare that the new context of the initializer after macro expansion enables access to `self`. `selfUnavailable` is the default value, and resembles the current behavior of accessor macros.

```swift
// Declaration of the example `@Lazy` macro
//
// We promise to use the initializer in a context where `self` is available:
@attached(accessor, initialization: selfAvailable, names: named(get), named(set))
@attached(peer, names: prefixed(_))
public macro Lazy() = #externalMacro( ... )

// Usage:

struct Earth {
    let mice = 21
    
    // ✅ We can use `self` here:
    @Lazy var theAnswer = self.mice * 2
}
```

## Detailed design

The compiler type-checks a subsumed initializer expression in its original context _before_ any macro is expanded. The initializer is type-checked again in its new context after macro expansion. Type-checking in the initial context should not be disabled, because it enables type inference. The inferred type is available to the accessor macro and is often needed when forming the expansion. Consequently, it would be impossible to change the order of type-checking; macros cannot be expanded before the property type is inferred, hence the initializer must be type-checked first. The following example illustrates this using the aforementioned `@Lazy` macro.

First, the property type is established by checking the initializer:
```swift
@Lazy var foo = 42
//              ^ Inferred type is `Int` after type-checking property initializer
```

The macro is invoked with this information:
```swift
@Lazy var foo: Int = 42
//             ^ Macro can see inferred type `Int`
```

The macro uses the inferred type during expansion:
```swift
private var _foo: Int?
//                ^ Macro uses inferred type here

var foo: Int {
    get {
        if let value = _foo {
            return value
        }
        let newValue = 42
        //             ^ Macro has re-contextualized the initializer here.
        //               It will be checked again in this context to make sure
        //               the expansion is valid.
        _foo = newValue
        return newValue
    }
    set { _foo = newValue }
}
```

Since the initial initializer type-check happens before macro expansion, there is currently no information about how the initializer will be used by the macro. For example, it could be used in an `init` accessor. The initializer would be evaluated during initialization of the enclosing type, when there is no access to `self`. For such a situation, the current implementation is correct: `self` is not available during type-checking in the original context.

Other macros such as `@Lazy` may result in an expansion where `self` access would be valid for the re-contextualized initializer. Currently, this fact is unknown during the initial check; therefore, `self` access is assumed to be illegal.

### Role Declaration

This proposal adds an optional `initialization:` parameter to the macro role declaration of accessor macros. It can have one of two possible arguments: either `selfAvailable` or `selfUnavailable`.

- `selfUnavailable`: The current behavior – no `self` access for the property initializer
- `selfAvailable`: The macro promises to use the initializer in a context where `self` is available

If the `initialization:` parameter is omitted, `selfUnavailable` will be used as the default value. This choice makes sure that existing macros behave the same as before.

Some example declarations:

```swift
// Declaration of the `@Lazy` macro
//
// We promise to use the initializer in a context where `self` is available:
@attached(accessor, initialization: selfAvailable, names: named(get), named(set))
@attached(peer, names: prefixed(_))
public macro Lazy() = #externalMacro( ... )

// This macro uses the initializer in an `init` accessor, where `self` access
// would be invalid.
@attached(accessor, initialization: selfUnavailable, names: named(init))
public macro SomeEagerMacro() = #externalMacro( ... )

// If `self` is not available for the initializer,
// we can just omit the `initialization:` property.
@attached(accessor, names: named(init))
public macro SomeEagerMacro() = #externalMacro( ... )

// `initialization:` is only available for accessor macros.
@attached(body, initialization: selfAvailable)
//        |     |˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜
//        |     |- 🛑 Error: 'initialization' unsupported for body macros
//        |     `- 🔧 Fix-it: remove 'initialization: selfAvailable'
//        `- 🔧 Fix-it: did you mean 'accessor' here?

// Only `selfAvailable` or `selfUnavailable` are valid:
@attached(accessor, initialization: ridiculous, names: named(get), named(set))
//                                  |- 🛑 Error: Unknown initialization context kind
//                                  |- 🔧 Fix-it: replace 'ridiculous' with 'selfAvailable'
//                                  |- 🔧 Fix-it: replace 'ridiculous' with 'selfUnavailable'
//                                  `- 🔧 Fix-it: remove 'initialization: ridiculous' for default "selfUnavailable" context

// `initialization:` takes one argument:
@attached(accessor, initialization: ridiculous, absurd, names: named(get), named(set))
//                                  ˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜
//                                  |- 🛑 Error: 'initialization' does not support multiple arguments
//                                  |- 🔧 Fix-it: replace 'ridiculous, absurd' with 'selfAvailable'
//                                  |- 🔧 Fix-it: replace 'ridiculous, absurd' with 'selfUnavailable'
//                                  `- 🔧 Fix-it: remove 'initialization: ridiculous, absurd' for default "selfUnavailable" context

// Fix-it for multiple arguments if one of them is valid:
@attached(accessor, initialization: selfAvailable, ridiculous, names: named(get), named(set))
//                                  ˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜˜
//                                  |- 🛑 Error: 'initialization' does not support multiple arguments
//                                  `- 🔧 Fix-it: keep 'selfAvailable'
```

### Effect on Type Checking

When checking the initializer in its original context, the type-checker will look for an accessor macro with an `initialization: selfAvailable` declaration attached. If such a macro is found, the same type-checking code as implemented for the existing `lazy` keyword is used, where `self` access is allowed. In all other cases, the behavior remains unchanged: `self` access is diagnosed as a compiler error.

If the macro author promises `selfAvailable` behavior in the role declaration, but re-contextualizes the initializer where `self` access is illegal, the type-checker will allow `self` access in the initializer's original context. The initializer expression will be checked again in its new context after macro expansion. An error will be diagnosed in the expanded code as expected.

```swift
// Macro declaration:
@attached(accessor, initialization: selfAvailable, names: named(get), named(init))
@attached(peer, names: prefixed(_))
public macro NotLazy() = #externalMacro( ... )

// Macro usage:
struct Earth {
    let mice = 21
    @NotLazy var theAnswer = mice * 2
}

// Expansion:
struct Earth {
    let mice = 21
    private var _theAnswer: Int
    var theAnswer: Int {
        @storageRestrictions(initializes: _theAnswer)
        init {
            _theAnswer = mice * 2
//                       ^ 🛑 cannot use instance member 'mice' within property initializer; property initializers run before 'self' is available
        }
        get { _theAnswer }
    }
}

```

## Source compatibility

Additive. Existing macro role declarations may remain unchanged. In this case, today's behavior remains unaffected.

## ABI compatibility

No effect on ABI.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code. No new runtime version is necessary. The proposed changes do not depend on new library features.

## Alternatives considered

### Enable `self` for all Subsumed Initializers in General

It could be argued that subsumed property initializers should always be allowed to access `self` and its instance members _in general_, since invalid access would be diagnosed in their new context later.

This approach would introduce source-compatibility problems where the meaning of a reference changes if `self` becomes available.

- A static member has the same name as an instance member:
  ```swift
  struct S {
    let foo = 0
    static let foo = 17

    // Used to be initialized with the static member.
    // Now it's initialized with the instance member.
    @Lazy var x = foo
  }
  ```
- There is an instance member named `self`. For example, classes deriving from `NSObject` have a `self()` method:
  ```swift
  class C: NSObject {
    // Used to be an unapplied reference to the inherited method "`self`() -> Self"
    // Now it's an instance of `C`
    @Lazy var x = self
  }
  ```

The proposed solution addresses this concern by giving macro authors control over granting `self` access. Making `selfAvailable` for existing macros should be carefully considered and documented as potentially source-breaking by macro vendors.

### Use Introduced Names to Infer Initialization Context

The type checker has access to the introduced names of an accessor macro. Instead of having the macro author declare `selfAvailable` or `selfUnavailable`, the type-checker could assume that `self` is available in the new context if the following conditions are met:

- macro introduces non-observing accessors
- macro does _not_ introduce an init accessor, assuming the initializer would be used here

This approach could work in the general case, but we can construct situations where it breaks down. For example, a macro may introduce an `init` accessor that is unrelated to the initializer expression. Instead, the initializer is actually used inside the getter. `self` access would have been OK in this context, but the type checker would diagnose an error.

Furthermore, this approach would cause existing macros to _automatically_ adopt the new behavior if they fulfill the conditions, raising source-compatibility concerns as described above. Macro authors should have control over adopting this feature.

### Macro + Existing `lazy` Keyword

There was a [discussion](https://forums.swift.org/t/accessor-macros-and-lazy-properties/73869) about attaching a macro to a `lazy var`. An effect of the `lazy` keyword is that `self` can be used in the initializer, which would achieve the desired behavior. However, the compiler diagnoses an error:

```swift
@MyMacro
lazy var value = self.compute()
// 🛑 'lazy' cannot be used on a computed property
```
This error is correct, because the compiler cannot check if the macro is actually lazy. If this combination was allowed, the programmer would need to know the internals of the macro implementation at the usage site and make sure that the `lazy` keyword is used correctly. This idea has been [rejected previously](https://github.com/swiftlang/swift-syntax/pull/2800).

### Naming

Initially, the proposed spelling was `initialization: lazy|eager`. It matched the precedent of the `lazy` keyword nicely, but did not adequately describe what is actually happening during type-checking. The same reasoning applies to the alternative `initialization: deferred|immediate` spelling.

A boolean `selfAvailable: true|false` was considered. Here it is unclear _where_ `self` is available/unavailable (the initializer expression).

### Adding `initialization: ignored`

There could be a third option `initialization: ignored` in addition to the proposed `selfAvailable` and `selfUnavailable`. If a macro declares that it will ignore the initializer, a warning would be diagnosed if adopting code supplies an initializer. However, the benefit is questionable. Macros can already be implemented to emit a diagnostic as needed.

The `intitialization:` parameter is still open for expansion to other options if the need arises in the future, since it is not limited to a boolean `true|false`.
