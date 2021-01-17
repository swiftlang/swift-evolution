# Static and class subscripts

* Proposal: [SE-0254](0254-static-subscripts.md)
* Author: [Becca Royal-Gordon](https://github.com/beccadax)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 5.1)**
* Implementation: [apple/swift#23358](https://github.com/apple/swift/pull/23358)
* Review: ([review](https://forums.swift.org/t/se-0254-static-and-class-subscripts/22537), [acceptance](https://forums.swift.org/t/accepted-se-0254-static-and-class-subscripts/22941))

## Introduction

We propose allowing `static subscript` and, in classes, `class subscript` declarations. These could be used through either `TypeName[index]` or `TypeName.self[index]` and would have all of the capabilities you would expect of a subscript. We also propose extending dynamic member lookup to static properties by using static subscripts.

Swift-evolution thread: [Static Subscript](https://forums.swift.org/t/static-subscript/1229) (2016), [Pitch: Static and class subscripts](https://forums.swift.org/t/pitch-static-and-class-subscripts/21850)

## Motivation

Subscripts have a unique and useful combination of features. Like functions, they can take arguments to change their behavior and generic parameters to support many types; like properties, they are permitted as lvalues so their results can be set, modified, and passed as inout. This is a powerful feature set, which is why they are used for features like key paths and `@dynamicMemberLookup`.

Unfortunately, unlike functions and properties, Swift only supports subscripts on regular types, not metatypes. This not only makes the language inconsistent, it also prevents us from supporting important language features on metatypes.

> <details>
> <summary>(Wait, what the heck is a "metatype"?)</summary>
>
> A type like `Int` has many instances, like `0` and `-42`. But Swift also creates a special instance representing the `Int` type itself, as opposed to any specific `Int` belonging to that type. This special instance can be directly accessed by writing `Int.self`; it is also returned by `type(of:)` and used in various other places. In fact, static members of `Int` are instance members of `Int.self`, so you use it any time you call one of those.
>
> Since `Int.self` is an instance, it must have a type, but the type of `Int.self` is not `Int`; after all, `Int.self` cannot do the things an `Int` can do, like arithmetic and comparison. Instead, `Int.self` is an instance of the type `Int.Type`. Because `Int.Type` is the type of a type, it is called a "metatype".
> </details>

And occasionally a subscript on a type is truly the best way to represent an operation. For instance, suppose you're offering access to the process's environment variables. Since the environment is global and environment variables can be both retrieved and set, a static subscript would be an excellent representation of them. Without them, users must either introduce a singleton instance or [use static properties or subscripts to expose the same operations with less fidelity](https://github.com/apple/swift-package-manager/blob/master/Sources/Basic/ProcessEnv.swift#L15).

Swift originally omitted static subscripts for a good reason: They conflicted with an early sugar syntax for arrays, `Element[]`. But we have long since changed that syntax to `[Element]` and we aren't going back. There is no longer a technical obstacle to supporting them, and there never was a philosophical one. The only obstacle to this feature is inertia.

It's time we gave it a little push.

## Proposed solution

In any place where it was previously legal to declare a `subscript`, it will now be legal to declare a `static subscript` as well. In classes it will also be legal to declare a `class subscript`.

```swift
public enum Environment {
  public static subscript(_ name: String) -> String? {
    get {
      return getenv(name).map(String.init(cString:))
    }
    set {
      guard let newValue = newValue else {
        unsetenv(name)
        return
      }
      setenv(name, newValue, 1)
    }
  }
}
```

The static and class subscripts on a type `T` can be used on any expression of type `T.Type`, including `T.self[...]` and plain `T[...]`.

```swift
Environment["PATH"] += ":/some/path"
```

A static subscript with the parameter label `dynamicMember` can also be used to look up static properties on types marked with `@dynamicMemberLookup`.

```swift
@dynamicMemberLookup
public enum Environment {
  public static subscript(_ name: String) -> String? {
    // as before
  }

  public static subscript(dynamicMember name: String) -> String? {
    get { return self[name] }
    set { self.name = newValue }
  }
}

Environment.PATH += ":/some/path"
```

We do not currently propose to add support for metatype key paths, but this proposal is a necessary prerequisite for any future work on them.

One concern brought up during the pitch phase was discoverability. We think that code completion changes will help with this, but those are outside the scope of an Evolution proposal.

## Detailed design

### Static subscripts

Static and class subscripts can be declared everywhere static and class computed properties can be, with analogous language rules. In particular, static and class subscript accessors are implicitly `nonmutating` and cannot be made `mutating`, just like static and class computed property accessors.

If a static or class subscript is declared on a type `T`, it can be applied to any value of type `T`, including `T.self`, `T`, and variables or other expressions evaluating to a value of type `T.Type`.

Objective-C class methods with the same selectors as instance subscript methods (like `+objectAtIndexedSubscript:`) will not be imported to Swift as class subscripts; Objective-C technically allows them but doesn't make them usable in practice, so this is no worse than the native experience. Likewise, it will be an error to mark a static or class subscript with `@objc`.

### Dynamic member lookup

`@dynamicMemberLookup` can be applied to any type with an appropriate `subscript(dynamicMember:)` or `static subscript(dynamicMember:)` (or `class subscript(dynamicMember:)`, of course). If `subscript(dynamicMember:)` is present, it will be used to find instance members; if `static subscript(dynamicMember:)` is present, it will be used to find static members. A type can provide both.

## Source compatibility

This proposal is purely additive; it does not change any prevously existing behavior. All syntax it will add support for was previously illegal.

## ABI compatibility and backwards deployment

Static subscripts are an additive change to the ABI. They do not require any runtime support; the Swift 5.0 runtime should even demangle their names correctly. Dynamic member lookup is implemented in the type checker and has no backwards deployment concerns.

## Effect on API resilience

The rules for the resilience of static and class subscripts will be the same as the rules of their instance subscript equivalents. Dynamic member lookup does not impact resilience.

## Alternatives considered

### Leave our options open

The main alternative is to defer this feature again, leaving this syntax unused and potentially available for some other purpose.

The most compelling suggestion we've seen is using `Element[n]` as type sugar for fixed-size arrays, but we don't think we would want to do that anyway. If fixed-size arrays need a sugar at all, we would want one that looked like an extension of the existing `Array` sugar, like `[Element * n]`. We can't really think of any other possibilities, so we feel confident that we won't want the syntax back in a future version of Swift.

## Future directions

### Metatype key paths

Swift does not currently allow you to form keypaths to or through static properties. This was no loss before static subscripts, since you wouldn't have been able to apply them to a metatype anyway. But now that we have static subscripts, metatype keypaths could be supported.

Metatype key paths were left out of this proposal because they are more complex than dynamic member lookup:

1. Making them backwards deploy requires certain compromises, such as always using opaque accessors. Are these worth the cost?

2. If we allow users to form key paths to properties in resilient libraries built before static key paths are supported, their `Equatable` and `Hashable` conformances may return incorrect results. Should we accept that as a minor issue, or set a minimum deployment target?

3. Metatypes have kinds of members not seen in instances; should we allow you to form key paths to them? (Forming a key path to a no-argument case may be particularly useful.)

These issues both require more implementation effort and deserve more design attention than metatype key paths could get as part of this proposal, so it makes sense to defer them. Nevertheless, this proposal is an important step in the right direction.
