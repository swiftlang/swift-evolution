# Static and class subscripts

* Proposal: [SE-0252](0252-static-subscripts.md)
* Authors: [Brent Royal-Gordon](https://github.com/brentdax)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#23358](https://github.com/apple/swift/pull/23358)

## Introduction

We propose allowing `static subscript` and, in classes, `class subscript` declarations. These could be used through either `TypeName[index]` or `TypeName.self[index]` and would have all of the capabilities you would expect of a subscript. We also propose extending dynamic member lookup and key paths to static properties by using static subscripts.

Swift-evolution thread: [Static Subscript](https://forums.swift.org/t/static-subscript/1229) (2016), [Pitch: Static and class subscripts](https://forums.swift.org/t/pitch-static-and-class-subscripts/21850)

## Motivation

Subscripts have a unique and useful combination of features. Like functions, they can take arguments to change their behavior and generic parameters to support many types; like properties, they are permitted as lvalues so their results can be set, modified, and passed as inout. This is a powerful feature set, which is why they are used for features like key paths and `@dynamicMemberLookup`.

Unfortunately, unlike functions and properties, Swift only supports subscripts on regular types, not metatypes. This not only makes the language inconsistent, it also prevents us from supporting key paths and dynamic members on metatypes.

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

Finally, it will be possible to form key paths rooted in or passing through metatypes, and to look up metatype-rooted key paths using a static subscript with the label `keyPath`.

```swift
let tableNameProperty = \Record.Type.tableName
Person[keyPath: tableNameProperty]
```

One concern brought up during the pitch phase was discoverability. We think that code completion changes will help with this, but those are outside the scope of an Evolution proposal.

## Detailed design

### Static subscripts

Static subscripts can be declared in classes, enums, structs, and protocols, as well as extensions thereof; class subscripts can be declared in classes and extensions of classes. In classes, static subscripts are implicitly `final`, but class subscripts are not.

Static and class subscripts will support all relevant features that instance subscripts do, including accessors, multiple parameters, labeled parameters, overloads, and generics. Since metatypes are reference types, static subscript accessors will not support the `mutating` and `nonmutating` keywords; this is the same behavior seen in classes and static property accessors.

Objective-C class methods with the same selectors as instance subscript methods (like `+objectAtIndexedSubscript:`) will not be imported to Swift as class subscripts; Objective-C technically allows them but doesn't make them usable in practice, so this is no worse than the native experience. Likewise, it will be an error to mark a static or class subscript with `@objc`.

### Dynamic member lookup

`@dynamicMemberLookup` can be applied to any type with an appropriate `subscript(dynamicMember:)` or `static subscript(dynamicMember:)` (or `class subscript(dynamicMember:)`, of course). If `subscript(dynamicMember:)` is present, it will be used to find instance members; if `static subscript(dynamicMember:)` is present, it will be used to find static members. A type can provide both.

### Key paths

It will be possible to form and use key paths involving static properties and subscripts. If a key path starts in a metatype, its `Root` type will be `Foo.Type`, where `Foo` is the type it's on. Settable key paths will always be `ReferenceWritableKeyPath`s, since metatypes are reference types. We don't believe this feature will require any runtime changes.

## Source compatibility

This proposal is purely additive; it does not change any prevously existing behavior. All syntax it will add support for was previously illegal.

## ABI compatibility and backwards deployment

Static subscripts are an additive change to the ABI. They do not require any runtime support; the Swift 5.0 runtime should even demangle their names correctly. Dynamic member lookup is implemented in the type checker and has no backwards deployment concerns.

Metatype key paths will always use accessors; doing this will ensure that they backwards deploy to Swift 5.0 correctly. Swift 5.0 code should also be able to access values through metatype key paths and otherwise use them without noticing anything different about them.

We anticipate one fly in the ointment: The `Equatable` and `Hashable` conformances for key paths may return incorrect results for static properties in resilient libraries built with the Swift 5.0 compiler. That is, if you form a key path to a static property in a system framework, the `==` operator may return incorrect results on machines running macOS 10.14.4/iOS 12.2/etc. or older. (This is because Swift 5.0 didn't emit resilient descriptors for static properties, so there is no agreed-upon stable identifier for `==` to use.) We think the impact of this issue will be tolerable and it can simply be documented.

## Effect on API resilience

The rules for the resilience of static and class subscripts will be the same as the rules of their instance subscript equivalents.

## Alternatives considered

### Leave our options open

The main alternative is to defer this feature again, leaving this syntax unused and potentially available for some other purpose.

The most compelling suggestion we've seen is using `Element[n]` as type sugar for fixed-size arrays, but we don't think we would want to do that anyway. If fixed-size arrays need a sugar at all, we would want one that looked like an extension of the existing `Array` sugar, like `[Element * n]`. We can't really think of any other possibilities, so we feel confident that we won't want the syntax back in a future version of Swift.
