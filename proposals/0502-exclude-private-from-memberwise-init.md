# Exclude private initialized properties from memberwise initializer

* Proposal: [SE-0502](0502-exclude-private-from-memberwise-init.md)
* Authors: [Hamish Knight](https://github.com/hamishknight), [Holly Borla](https://github.com/hborla)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Accepted**
* Implementation: [swiftlang/swift#84514](https://github.com/swiftlang/swift/pull/84514)
* Experimental Feature Flag: `ExcludePrivateFromMemberwiseInit`
* Review: ([pitch](https://forums.swift.org/t/pitch-exclude-private-initialized-properties-from-memberwise-initializer/83348)) ([review](https://forums.swift.org/t/se-0502-exclude-private-initialized-properties-from-memberwise-initializer/84022)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0502-exclude-private-initialized-properties-from-memberwise-initializer/84565))

## Introduction

We propose changing the rules for the implicit memberwise initializer such that it does not include properties with initial values that are less accessible than the most accessible property in the initializer, up to `internal`. This ensures that the resulting memberwise initializer is not unnecessarily forced to be `private` when introducing a new `private` property with an initial value.

## Motivation

The implicit memberwise initializer is automatically synthesized for `struct` declarations containing one or more initializable properties. It serves as a convenient way of initializing the aggregate value without needing to manually write the boilerplate of an initializer that takes every property as an argument and initializes the property with its corresponding value.

```swift
struct S {
  var x: Int
  var y: Int
  // Synthesized memberwise init:
  // init(x: Int, y: Int) {
  //   self.x = x
  //   self.y = y
  // }
}

let s = S(x: 1, y: 2)
```

However, this synthesized initializer comes with a catch. If you declare a `private` or `fileprivate` property with an initial value, it gets included in the memberwise initializer and forces the initializer to be limited to that access level. This limits its utility and in many cases forces the user to manually define their own memberwise initializer.

```swift
struct S {
  var x: Int
  var y: Int
  private var z = 0
}

let s = S(x: 1, y: 2) // error: 'S' initializer is inaccessible due to 'private' protection level
```

This is particularly problematic for attached macros that aim to provide property-wrapper-like behavior. With property wrappers, the compiler already excludes the `private` backing property from the memberwise initializer, as well as the property itself if it has an initial value and is either `fileprivate` or `private`.

```swift
@propertyWrapper
struct Wrapper<T> {
  var wrappedValue: T
}

struct S {
  @Wrapper private var x = 1
  var y: Int
}
let s = S(y: 2) // Okay
``` 

Attempting to replace `Wrapper` with an equivalent macro in a source compatible way is currently impossible without also requiring the user to manually reimplement the memberwise initializer, since the expansion needs to be able to add a `private` backing property to the type (and if an `init` accessor were used, the fact that `x` itself is `private` would still be problematic).

## Proposed solution

We propose changing the rules for the implicit memberwise initializer such that it does not include properties with initial values that are less accessible than the most accessible property in the initializer, up to `internal`. A compatibility overload will also be introduced to allow uses of the old signature to continue to work until a future language mode.

## Detailed design

To determine whether or not a property is included in the memberwise initializer, we first compute the maximum access level the initializer can be. This is given by the maximum access level of the properties that are memberwise initializable (i.e properties that are currently included in the memberwise initializer), limited to a maximum of `internal`. The access level of an unannotated property is implicitly considered to be the access level of the enclosing type, as the memberwise initializer for `(file)private` type can only ever be `fileprivate` at most.

The memberwise initializer is then defined as including all memberwise initializable properties except those that are both below this maximum access level and have an initial value. "Initial value" the purposes of this proposal is defined as either:

- Having an explicitly declared initial value e.g `private var x = 0`
- Having a default initialized value e.g `private var x: Int?`

Note that this can also include computed properties that have `init` accessors, provided they have initial values.

This rule change means that the example from above becomes legal:

```swift
struct S {
  var x: Int
  var y: Int
  private var z = 0
}

let s = S(x: 1, y: 2)
```

The memberwise initializer here has a maximum access level of `internal`, and as such does not include `z`, which is less accessible and has an initial value. The same would also apply if `z` were `fileprivate`.

However for a case such as the following:

```swift
struct S {
  private var x = 0
  private var y: Int?
}
```

There is no change in behavior since the maximum access level is `private`, so both properties continue to be included in the initializer, which itself is `private`. If `y` were changed to `fileprivate`, then the memberwise initializer would become `fileprivate` and `x` would be excluded.

In cases where a less accessible property exists without an initial value, the memberwise initializer will continue to include it, and will have the same access level as before:

```swift
struct S {
  var x: Int
  private var y: Int
}

let s = S(x: 0, y: 1) // error: 'S' initializer is inaccessible due to 'private' protection level
```

In cases where the type itself is `(file)private`, its properties are also effectively `fileprivate` if no other access level is specified. As such, both `x` and `y` are included in the memberwise initializer here since its maximum access level is `fileprivate`:

```swift
fileprivate struct S {
  var x: Int?
  fileprivate var y: Int?
}

let s = S(x: 0, y: 1) // Fine
```

Since the memberwise initializer is only ever `internal` at most, a more accessible property has no effect on the behavior:

```swift
public struct S {
  public var x: Int = 0
  var y: Int = 0
}

let s = S(x: 0, y: 1) // Fine
```

The memberwise initializer will continue to include both `x` and `y` since its maximum access level is still `internal`.

### Compatibility overload

The above change alone is not source compatible since types may currently be relying on the memberwise initializer to initialize `private` properties of the type. This would become illegal if that type has another memberwise initializable property with a greater access level. Given that the resulting initializer is forced to be `private` or `fileprivate` in these cases, this only affects uses that are in the same file. To help mitigate the compatibility for these cases, the compiler will continue to synthesize a separate compatibility overload of the memberwise initializer that contains the same properties as before the change.

## Source compatibility

The compatibility overload helps significantly mitigate the source compatibility impact of this change, but there are a couple of cases that are not source compatible with this change.

The first case is when a base-name-only unbound reference to the initializer is used without a contextual type, e.g `let fn = S.init`. Such a reference will favor the overload with fewer default arguments and as such will prefer the new memberwise initializer. As such any downstream uses of it would likely become an error due to the missing parameters. We expect these cases to be very rare though.

The second affects cases where an overload of the new memberwise initializer signature is already defined in an extension of the type.

```swift
struct S {
  private var x: Int = 0
  var y: String
}

extension S {
  init(y: String) {
    self.init(x: 0, y: "")
  }
}
```

The above example is legal today, but will become illegal with the proposed change since the initializer overload in the extension does not suppress the synthesis of the memberwise initializer in the type body. As such, it will result in a redeclaration error. We expect such cases to be extremely rare though, and haven't yet encountered any such examples in our source compatibility testing so far.

## ABI compatibility

The implicit memberwise initializer is only ever `internal` at most, and as such this change does not impact ABI.

## Implications on adoption

There are no deployment or ABI concerns with adopting this feature. As the memberwise initializer is only ever `internal` at most, any source compatibility impact is limited to the module in which the type is defined. As explored in the source compatibility section, the introduction of a compatibility overload allows users to continue using the original variant of the memberwise initializer until the next language mode.

## Future directions

### Deprecating the compatibility memberwise initializer

In a future language mode we could consider removing the compatibility overload, with a warning and fix-it that inserts an explicit version of the initializer to help users migrate prior to adopting the new language mode. Given this only affects uses in the same file, the compiler could emit this warning on the type itself if any use of the compatibility overload is present:

```swift
struct S {
  // ^ warning: synthesized memberwise initializer no longer includes 'x'; uses of it will be an error in a future Swift language mode
  // ^ note: insert an explicit implementation of the memberwise initializer

  private var x: Int?
  var y: String

  // New memberwise initializer:
  // internal init(y: String)

  // Compatibility overload:
  // private init(x: Int? = nil, y: String)

  func foo() -> S {
    S(x: x, y: "hello \(y)") // note: memberwise initializer used here
  }
}
```

An upcoming feature flag could also be available to allow adopting the feature without the compatibility overload.

### Fully customizable memberwise initializer

We could introduce a mechanism that allows full customization of the memberwise initializer, either through the introduction of an attribute that could be attached to properties to explicitly spell whether they should be included or excluded, or potentially through a macro-like syntax, e.g:

```swift
struct S {
  private var x = 0
  var y: Int
  var z = "hello"
  
  public #memberInit(x, y)
}
```

Which defines a `public` memberwise initializer that includes `x` but excludes `z`. Unfortunately this isn't yet supportable natively through macros since it potentially requires type-checking initializers of properties that don't have type annotations. Alternatively, this could be supported with a new `memberwise` keyword as explored by [SE-0018][SE-0018].

While we think this is an interesting future direction, we don't think it should block improving the _default_ memberwise initializer behavior.


## Alternatives considered

### Only exclude `private` and/or `fileprivate`

Instead of excluding properties based on the maximum access level of the memberwise initializer, we could choose to blanket exclude either `private` or both `private` and `fileprivate` properties as long as they have initial values. The latter of which would align with the current behavior for properties with attached property wrappers.

We decided against this, since through source compatibility testing this variant of the change, it was somewhat common for a type to define only `private` or `fileprivate` properties with initial values. In such cases, it can still be useful to have an implicitly generated memberwise initializer. Changing the rule to be based on the maximum access level significantly cut down the impact of this change (e.g in the source compatibility suite it reduced the impact from 4 projects to 1).

### Only exclude `private` macro-expanded properties

Rather than changing the behavior for properties in general, we could limit the behavior change such that it only applies to properties introduced by macro expansions. We dislike this option since it breaks the principle of applied macros being equivalent to their expansions - a principle that allows you to copy and paste a macro expansion directly into your code without any semantic changes. Additionally, we feel that this is a problem that is worth fixing in the general case, not just for macros.

### Exclude `private(set)`/`fileprivate(set)` properties

When computing the maximum access level, we could take the access level of the setter into account, such that properties with `(file)private` setters are excluded in more cases. However we chose not to do this to match the existing access level behavior of the memberwise initializer, which only takes the overall access level of the property into account.

### Avoid restricting the access level of the initializer

Rather than restricting what properties are included in the memberwise initializer, we could choose to solve this issue by making all memberwise initializers `internal`. We are not convinced this is the right way to solve the issue since it would expose private implementation details of the type as part of its non-private interface.

### Synthesize an overload for each access level

We could potentially synthesize a corresponding overload of the memberwise initializer for each access level that has a distinct set of initializable properties. We don't think this is a good long-term solution though, we think a single overload should be sufficient for the majority of use cases. More overloads would instead be better handled by a future language feature that allows customizing the desired behavior, as explored above in future directions.

### Introduce an attribute to allow excluding a property

As mentioned in the future directions, we could potentially have an attribute that you could add to a property to indicate that it should not be included in the memberwise initializer. However this wouldn't on its own resolve the fact that the default behavior is still surprising. As such we feel it is better explored as part of a future direction that allows fully customizing the memberwise initializer.

  [SE-0018]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0018-flexible-memberwise-initialization.md
