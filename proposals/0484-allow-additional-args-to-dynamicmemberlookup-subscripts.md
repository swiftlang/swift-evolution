# Allow Additional Arguments to `@dynamicMemberLookup` Subscripts

* Proposal: [SE-0484](0484-allow-additional-args-to-dynamicmemberlookup-subscripts.md)
* Authors: [Itai Ferber](https://github.com/itaiferber)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Accepted**
* Implementation: [swiftlang/swift#81148](https://github.com/swiftlang/swift/pull/81148)
* Previous Proposals: [SE-0195](0195-dynamic-member-lookup.md), [SE-0252](0252-keypath-dynamic-member-lookup.md)
* Review: ([pitch](https://forums.swift.org/t/pitch-allow-additional-arguments-to-dynamicmemberlookup-subscripts/79558)) ([review](https://forums.swift.org/t/se-0484-allow-additional-arguments-to-dynamicmemberlookup-subscripts/79853)) ([acceptance](https://forums.swift.org/t/accepted-se-0484-allow-additional-arguments-to-dynamicmemberlookup-subscripts/80167))

## Introduction

SE-0195 and SE-0252 introduced and refined `@dynamicMemberLookup` to provide type-safe "dot"-syntax access to arbitrary members of a type by reflecting the existence of certain `subscript(dynamicMember:)` methods on that type, turning

```swift
let _ = x.member
x.member = 42
ƒ(&x.member)
```

into

```swift
let _ = x[dynamicMember: <member>]
x[dynamicMember: <member>] = 42
ƒ(&x[dynamicMember: <member>])
```

when `x.member` doesn't otherwise exist statically. Currently, in order to be eligible to satisfy `@dynamicMemberLookup` requirements, a subscript must:

1. Take _exactly one_ argument with an explicit `dynamicMember` argument label,
2. Whose type is non-variadic and is either
   * A `{{Reference}Writable}KeyPath`, or
   * A concrete type conforming to `ExpressibleByStringLiteral`

This proposal intends to relax the "exactly one" requirement above to allow eligible subscripts to take additional arguments after `dynamicMember` as long as they have a default value (or are variadic, and thus have an implicit default value).

## Motivation

Dynamic member lookup is often used to provide expressive and succinct API in wrapping some underlying data, be it a type-erased foreign language object (e.g., a Python `PyVal` or a JavaScript `JSValue`) or a native Swift type. This (and [`callAsFunction()`](0253-callable.md)) allow a generalized API interface such as

```swift
struct Value {
    subscript(_ property: String) -> Value {
        get { ... }
        set { ... }
    }

    func invoke(_ method: String, _ args: Any...) -> Value {
        ...
    }
}

let x: Value = ...
let _ = x["member"]
x["member"] = Value(42)
x.invoke("someMethod", 1, 2, 3)
```

to be expressed much more naturally:

```swift
@dynamicMemberLookup
struct Value {
    struct Method {
        func callAsFunction(_ args: Any...) -> Value { ... }
    }

    subscript(dynamicMember property: String) -> Value {
        get { ... }
        set { ... }
    }

    subscript(dynamicMember method: String) -> Method { ... }
}

let x: Value = ...
let _ = x.member
x.member = Value(42)
x.someMethod(1, 2, 3)
```

However, as wrappers for underlying data, sometimes interfaces like this need to be able to "thread through" additional information. For example, it might be helpful to provide information about call sites for debugging purposes:

```swift
struct Value {
    subscript(
        _ property: String,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Value {
        ...
    }

    func invokeMethod(
        _ method: String,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ args: Any...
    ) -> Value {
        ...
    }
}
```

When additional arguments like this have default values, they don't affect the appearance of call sites at all:

```swift
let x: Value = ...
let _ = x["member"]
x["member"] = Value(42)
x.invoke("someMethod", 1, 2, 3)
```

However, these are not valid for use with dynamic member lookup subscripts, since the additional arguments prevent subscripts from being eligible for dynamic member lookup:

```swift
@dynamicMemberLookup // error: @dynamicMemberLookupAttribute requires 'Value' to have a 'subscript(dynamicMember:)' method that accepts either 'ExpressibleByStringLiteral' or a key path
struct Value {
    subscript(
        dynamicMember property: String,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Value {
        ...
    }

    subscript(
        dynamicMember method: String,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Method {
        ...
    }
}
```

## Proposed solution

We can amend the rules for such subscripts to make them eligible. With this proposal, in order to be eligible to satisfy `@dynamicMemberLookup` requirements, a subscript must:

1. Take an initial argument with an explicit `dynamicMember` argument label,
2. Whose parameter type is non-variadic and is either:
    * A `{{Reference}Writable}KeyPath`, or
    * A concrete type conforming to `ExpressibleByStringLiteral`,
3. And whose following arguments (if any) are all either variadic or have a default value

## Detailed design

Since compiler support for dynamic member lookup is already robust, implementing this requires primarily:

1. Type-checking of `@dynamicMemberLookup`-annotated declarations to also consider `subscript(dynamicMember:...)` methods following the above rules as valid, and
2. Syntactic transformation of `T.<member>` to `T[dynamicMember:...]` in the constraint system to fill in default arguments expressions for any following arguments

## Source compatibility

This is largely an additive change with minimal impact to source compatibility. Types which do not opt in to `@dynamicMemberLookup` are unaffected, as are types which do opt in and only offer `subscript(dynamicMember:)` methods which take a single argument.

However, types which opt in to `@dynamicMemberLookup` and currently offer an overload of `subscript(dynamicMember:...)`—which today is not eligible for consideration for dynamic member lookup—_may_ now select this overload when they wouldn't have before.

### Overload resolution

Dynamic member lookups go through regular overload resolution, with an additional disambiguation rule that prefers keypath-based subscript overloads over string-based ones. Since the `dynamicMember` argument to dynamic member subscripts is implicit, overloads of `subscript(dynamicMember:)` are primarily selected based on their return type (and typically for keypath-based subscripts, how that return type is used in forming the type of a keypath parameter).

With this proposal, all arguments to `subscript(dynamicMember:...)` are still implicit, so overloads are still primarily selected based on return type, with the additional disambiguation rule that prefers overloads with fewer arguments over overloads with more arguments. (This rule applies "for free" since it already applies to method calls, which dynamic member lookups are transformed into.)

This means that if a type today offers a valid `subscript(dynamicMember:) -> T` and a (currently-unconsidered) `subscript(dynamicMember:...) -> U`,

1. If `T == U` then the former will still be the preferred overload in all circumstances
2. If `T` and `U` are compatible (and equally-specific) at a callsite then the former will still be the preferred overload
3. If `T` and `U` are incompatible, or if one is more specific than the other, then the more specific type will be preferred

For example:

```swift
@dynamicMemberLookup
struct A {
    /* (1) */ subscript(dynamicMember member: String) -> String { ... }
    /* (2) */ subscript(dynamicMember member: String, _: StaticString = #function) -> String { ... }
}

@dynamicMemberLookup
struct B {
    /* (3) */ subscript(dynamicMember member: String) -> String { ... }
    /* (4) */ subscript(dynamicMember member: String, _: StaticString = #function) -> Int { ... }
}

@dynamicMemberLookup
struct C {
    /* (5) */ subscript(dynamicMember member: String) -> String { ... }
    /* (6) */ subscript(dynamicMember member: String, _: StaticString = #function) -> String? { ... }
}

// T == U
let _ = A().member          // (1) preferred over (2); no ambiguity
let _: String = A().member  // (1) preferred over (2); no ambiguity

// T and U are compatible
let _: Any = A().member     // (1) preferred over (2); no ambiguity
let _: Any = B().member     // (3) preferred over (4); no ambiguity
let _: Any = C().member     // (5) preferred over (6); no ambiguity

// T and U are incompatible/differently-specific
let _: String = B().member  // (3)
let _: Int = B().member     // (4);️ would not previously compile
let _: String = C().member  // (5); no ambiguity
let _: String? = C().member // (6) preferred over (5); ⚠️ previously (5) ⚠️
```

This last case is the only source of behavior change: (6) was previously not considered a valid candidate, but has a return type more specific than (5), and is now picked at a callsite.

In practice, it is expected that this situation is exceedingly rare.

## ABI compatibility

This feature is implemented entirely in the compiler as a syntactic transformation and has no impact on the ABI.

## Implications on adoption

The changes in this proposal require the adoption of a new version of the Swift compiler.

## Alternatives considered

The main alternative to this proposal is to not implement it, as:
1. It was noted in [the pitch thread](https://forums.swift.org/t/pitch-allow-additional-arguments-to-dynamicmemberlookup-subscripts/79558) that allowing additional arguments to dynamic member lookup widens the gap in capabilities between dynamic members and regular members — dynamic members would be able to

   1. Have caller side effects (i.e., have access to `#function`, `#file`, `#line`, etc.),
   2. Constrain themselves via generics, and
   3. Apply isolation to themselves via `#isolation`

   where regular members cannot. However, (i) and (iii) are not considered an imbalance in functionality but instead are the raison d'être of this proposal. (ii) is also already possible today as dynamic member subscripts can be constrained via generics (and this is often used with keypath-based lookup).
2. This is possible to work around using explicit methods such as `get()` and `set(_:)`:

   ```swift
   @dynamicMemberLookup
   struct Value {
       struct Property {
           func get(
               function: StaticString = #function,
               file: StaticString = #file,
               line: UInt = #line
           ) -> Value {
               ...
           }

           func set(
               _ value: Value,
               function: StaticString = #function,
               file: StaticString = #file,
               line: UInt = #line
           ) {
               ...
           }
       }

       subscript(dynamicMember member: String) -> Property { ... }
   }

   let x: Value = ...
   let _ = x.member.get()  // x.member
   x.member.set(Value(42)) // x.member = Value(42)
   ```

   However, this feels non-idiomatic, and for long chains of getters and setters, can become cumbersome:

   ```swift
   let x: Value = ...
   let _ = x.member.get().inner.get().nested.get()  // x.member.inner.nested
   x.member.get().inner.get().nested.set(Value(42)) // x.member.inner.nested = Value(42)
   ```

### Source compatibility

It is possible to avoid the risk of the behavior change noted above by adjusting the constraint system to always prefer `subscript(dynamicMember:) -> T` overloads over `subscript(dynamicMember:...) -> U` overloads (if `T` and `U` are compatible), even if `U` is more specific than `T`. However,

1. This would be a departure from the normal method overload resolution behavior that Swift developers are familiar with, and
2. If `T` were a supertype of `U`, it would be impossible to ever call the more specific overload except by direct subscript access
