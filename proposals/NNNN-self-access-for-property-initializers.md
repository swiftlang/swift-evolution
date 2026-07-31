# Enable Macros to Grant `self` Access for Property Initializers

* Proposal: [SE-NNNN](NNNN-lazy-accessor-macros.md)
* Authors: [Nils Grabenhorst](https://github.com/nilsgrabenhorst)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#89757](https://github.com/swiftlang/swift/pull/89757)
* Review: ([pitch](https://forums.swift.org/t/pitch-lazy-accessor-macros/87515))

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
    //           ^ ❌ cannot use instance member 'mice' within property initializer; property initializers run before 'self' is available
    
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
    //              ^ ❌ cannot use instance member 'mice' within property initializer; property initializers run before 'self' is available
}
```
The error is unnecessarily limiting, because `@Lazy` moves the initializer into a `get` accessor, where `self` access is allowed. 

There is another [example](https://forums.swift.org/t/pitch-lazy-accessor-macros/87515#p-399664-concrete-example-2) in the original pitch, which shows how the proposed change could enable access to SwiftUI environment values when initializing `Observable` objects.

## Proposed solution

Add an optional `initializion:` parameter to the accessor macro role declaration. Possible values are `lazy` or `eager`. A macro author uses `lazy` to declare that the initializer is invoked lazily after macro expansion, which enables access to `self` in the initializer expression. `eager` is the default value, and resembles the current behavior of accessor macros.

```swift
// Declaration of the example `@Lazy` macro
//
// With `initializer: lazy`, we promise to use the initializer
// in a context where `self` is available.
@attached(accessor, initialization: lazy, names: named(get), named(set))
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

The compiler type-checks a subsumed initializer expression in its original context _before_ any macro is expanded. The initializer is type-checked again in its new context after an accessor macro is expanded. Type-checking in the initial context should not be disabled, because it enables type inference. The inferred type is available to the accessor macro and is often needed to form the expansion. Consequently, it would be impossible to change that order; macros cannot be expanded before the property type is inferred, hence the initializer must be type-checked first. The following example illustrates this using the aforementioned `@Lazy` macro. First, the property type is inferred by checking the initializer:

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

This proposal adds an optional `initialization:` parameter to the macro role declaration of accessor macros. It can have one of two possible arguments: either `eager` or `lazy`.

- `eager`: The current behavior – no `self` access for the property initializer
- `lazy`: The macro promises to use the initializer in a context where `self` is available

If the `initializer:` parameter is omitted, `eager` will be used as the default value. This choice makes sure that existing macros behave the same as before.

Some example declarations:

```swift
// Declaration of the `@Lazy` macro
//
// With `initialization: lazy`, we promise to use the initializer
// in a context where `self` is available.
@attached(accessor, initialization: lazy, names: named(get), named(set))
@attached(peer, names: prefixed(_))
public macro Lazy() = #externalMacro( ... )

/// This macro uses the initializer in an `init` accessor, where `self` access
/// would be invalid.
@attached(accessor, initialization: eager, names: named(init))
public macro SomeEagerMacro() = #externalMacro( ... )

/// If `self` is not available for the initializer,
/// we can just omit the `initialization:` property.
@attached(accessor, names: named(init))
public macro SomeEagerMacro() = #externalMacro( ... )

/// `initialization:` is only available for accessor macros.
@attached(body, initialization: lazy)
//              ^ ❌ Error: "initialization" is only available for accessor role

/// Only `lazy` or `eager` are valid:
@attached(accessor, initialization: ridiculous, names: named(get), named(set))
//                                  ^ ❌ Error: Unknown initialization context 'ridiculous'. Possible values are 'eager' or 'lazy'.

/// `initialization:` takes one argument:
@attached(accessor, initialization: eager, lazy, names: named(get), named(set))
//                                  ^ ❌ Error: multiple arguments unsupported.
```

### Effect on Type Checking

When checking the initializer in its original context, the type-checker will look for an accessor macro with an `initialization: lazy` declaration attached. If such a macro is found, the same type-checking code as implemented for the existing `lazy` keyword is used, where `self` access is allowed. In all other cases, the behavior remains unchanged: `self` access is diagnosed as a compiler error.

If the macro author promises `lazy` behavior in the role declaration, but re-contextualizes the initializer where `self` access is illegal, the type-checker will allow `self` access in the initializer's original context. The initializer expression will be checked again in its new context after macro expansion. An error will be diagnosed in the expanded code as expected.

```swift
// Macro declaration:
@attached(accessor, initialization: lazy, names: named(get), named(init))
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
//                       ^ ❌ cannot use instance member 'mice' within property initializer; property initializers run before 'self' is available
        }
        get { _theAnswer }
    }
}

```

## Source compatibility

Additive. Existing macro role declarations may remain unchanged. In this case, today's behavior remains unaffected.

Newly written accessor macros may elect to specify `lazy` initializer usage. This does not affect existing source code.

A macro author may elect to specify `lazy` initializer usage for an existing macro. This change may affect existing code:

```swift
struct Earth {
    static let someValue: Double = 17
    let someValue = 42
    
    // ⚠️ `theAnswer` used to be "17.0" before the macro author declared `lazy`.
    //     Now the answer is "42". Also, the inferred type has changed: It used
    //     to be `Double`, now it's `Int`.
    @NewlyLazy var theAnswer = someValue
}
```
Changing the initialization context from `eager` to `lazy` or vice-versa must therefore be carefully considered by the macro author. Such a change should only be considered for "major" source-breaking package version increments and clearly documented.

## ABI compatibility

No effect on ABI when using existing macros as-is. Using an existing macro that newly adopted `lazy` may cause a different type to be inferred in some cases as shown in the example above.

## Implications on adoption

This feature can be adopted and un-adopted in source code when considering the effect described in _Source compatibility_.

Code that uses accessor macros with a `lazy` property initializer does not require a new runtime version. The expanded code does not depend on new library features.

## Future directions

### Fix-its

Add fix-its to error diagnostics for accessor role declarations. Some examples:

```swift
// `initialization:` is only available for accessor macros.
@attached(body, initialization: lazy)
//              ^ ❌ Error: "initialization" is only available for accessor role
//                🔧 Fix: Remove "initialization: lazy"

// Only `lazy` or `eager` are valid:
@attached(accessor, initialization: ridiculous, names: named(get), named(set))
//                                  ^ ❌ Error: Unknown initializer context 'ridiculous'. Possible values are 'eager' or 'lazy'.
//                                    🔧 Fix: Use "lazy"
//                                    🔧 Fix: Use "eager"
//                                    🔧 Fix: Remove "initialization: ridiculous" for default eager initialization

/// `initialization:` takes one argument:
@attached(accessor, initialization: eager, lazy, names: named(get), named(set))
//                                  ^ ❌ Error: multiple arguments unsupported.
//                                    🔧 Fix: Use "lazy"
//                                    🔧 Fix: Use "eager"
//                                    🔧 Fix: Remove "initialization: eager, lazy, " for default eager initialization
```

## Alternatives considered

### Use Introduced Names to Infer Initializer Context

The type checker has access to the introduced names of an accessor macro. Instead of having the macro author declare `lazy` or `eager` usage, the type-checker could assume a lazy context if the following conditions are met:

- macro introduces non-observing accessors
- macro does _not_ introduce an init accessor, assuming the init expression will be used here

This approach could work in the general case, but we can construct situations where it breaks down. For example, a macro may introduce an `init` accessor that is unrelated to the initializer expression. Instead, the initializer is actually used lazily inside the getter. `self` access would have been OK for such a macro, but is forbidden by the type checker.

Another problem of this approach is that existing macros automatically adopt the new behavior if they fulfill the conditions. This may result in source-breaking changes or subtle bugs when an initializer suddenly uses `self.foo` instead of `Self.foo`.

### Macro + Existing `lazy` Keyword

There was a [discussion](https://forums.swift.org/t/accessor-macros-and-lazy-properties/73869) about attaching a macro to a `lazy var`. An effect of the `lazy` keyword is that `self` can be used in the initializer, which would achieve the desired behavior. However, the compiler diagnoses an error:

```swift
@MyMacro
lazy var value = self.compute()
// ❌ 'lazy' cannot be used on a computed property
```
This error is correct, because the compiler cannot check if the macro is actually lazy. If this combination was allowed, the programmer would need to know the internals of the macro implementation at the usage site and make sure that the `lazy` keyword is used correctly. This idea has been [rejected previously](https://github.com/swiftlang/swift-syntax/pull/2800).
