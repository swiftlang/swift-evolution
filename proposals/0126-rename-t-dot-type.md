# Rename `T.Type`

* Proposal: [SE-0126](0126-refactor-metatypes-repurpose-t-dot-self-and-mirror.md)
* Authors: [Adrian Zubarev](https://github.com/DevAndArtist), [Anton Zhilin](https://github.com/Anton3)
* Status: **Revision**
* Review manager: [Chris Lattner](http://github.com/lattner)
* Revision: 2
* Previous Revisions: [1](https://github.com/apple/swift-evolution/blob/83707b0879c83dcde778f8163f5768212736fdc2/proposals/0126-refactor-metatypes-repurpose-t-dot-self-and-mirror.md)

## Introduction

This proposal renames `T.Type` to `Metatype<T>`, renames `type(of:)` to `metatype(of:)` and removes `P.Protocol` metatypes.

Swift-evolution threads: 

* [\[Revision\] \[Pitch\] Rename `T.Type`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/025115.html)
* [\[Review\] SE-0126: Refactor Metatypes, repurpose T[dot]self and Mirror]()
* [\[Proposal\] Refactor Metatypes, repurpose T[dot]self and Mirror](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/024772.html) 
* [\[Discussion\] Seal `T.Type` into `Type<T>`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160704/023818.html)

## Motivation

<details><summary>Explanation of metatypes</summary>

For every type `T` in Swift, there is an associated metatype `T.Type`.

### Basics: function specialization

Let's try to write a generic function like `staticSizeof`. We will only consider its declaration; implementation is trivial and unimportant here.

Out first try would be:

```swift
func staticSizeof<T>() -> Int
staticSizeof<Float>()  // error :(
```

Unfortunately, it's an error. We can't explicitly specialize generic functions in Swift. Second try: we pass a parameter to our function and get generic type parameter from it:

```swift
func staticSizeof<T>(_: T) -> Int
staticSizeof(1)  //=> should be 8
```

But what if our type `T` was a bit more complex and hard to obtain? For example, think of `struct Properties` that loads a file on initialization:

```swift
let complexValue = Properties("the_file.txt")  // we have to load a file
staticSizeof(complexValue)                     // just to specialize a function
```

Isn't that weird? But we can work around that limitation by passing instance of a dummy generic type:

```swift
struct Dummy<T> { }
func staticSizeof<T>(_: Dummy<T>) -> Int
staticSizeof(Dummy<Properties>())
```

This is the main detail to understand: we **can** explicitly specialize generic types, and we **can** infer generic type parameter of function from generic type parameter of passed instance. Now, surprise! We've already got `Dummy<T>` in the language: it's called `T.Type` and created using `T.self`:

```swift
func staticSizeof<T>(_: T.Type) -> Int
staticSizeof(Float.self)
```

But there's a lot more to `T.Type`. Sit tight.

### Subtyping

Internally, `T.Type` stores identifier of a type. Specifically, `T.Type` can refer to any **subtype** of `T`. With enough luck, we can also cast instances of metatypes to other metatypes. For example, `Int : CustomStringConvertible`, so we can do this:

```swift
let subtype = Int.self
metaInt    //=> Int
let supertype = subtype as CustomStringConvertible.Type
supertype  //=> Int
```

Here, `supertype : CustomStringConvertible.Type` can refer to `Int`, to `String` or to any other `T : CustomStringConvertible`.
We can also use `as?`, `as!` and `is` to check subtyping relationships. We'll only show examples with `is`:

```swift
Int.self is CustomStringConvertible.Type  //=> true
```
```swift
protocol Base { }
protocol Derived: Base { }
Derived.self is Base.Type  //=> true
```
```swift
protocol Base { }
struct Derived: Base { }
let someBase = Derived.self as Base.Type
// ...
someBase is Derived.Type  //=> true
```

A common practise is to store metatypes `as Any.Type`. When needed, we can check all required conformances.

### Dynamic dispatch of static methods

If we have an instance of `T.Type`, we can call static methods of `T` on it:

```swift
struct MyStruct {
    static func staticMethod() -> String { return "Hello metatypes!" }
}
let meta = MyStruct.self
meta.staticMethod()  //=> Hello metatypes!
```

What is especially useful, if our `T.self` actually stores some `U : T`, then static method of `U` will be called:

```swift
protocol HasStatic { static func staticMethod() -> String }
struct A: HasStatic { static func staticMethod() -> String { return "A" } }
struct B: HasStatic { static func staticMethod() -> String { return "B" } }

var meta: HasStatic.Type
meta = A.self
meta.staticMethod()  //=> A
meta = B.self
meta.staticMethod()  //=> B
```

Summing that up, metatypes have far deeper semantics than a tool for specialization of generic functions. They combine dynamic information about a type with static information "contained type is a subtype of *this*". They can also dynamically dispatch static methods the same way as normal methods are dynamically dispatched.
</details>

### Current behavior of `.Protocol`

For protocols `P`, besides normal `P.Type`, there is also a "restricting metatype" `P.Protocol` that is the same as `P.Type`, except that it can only reflect `P` itself and not any of its subtypes:

```swift
Int.self is CustomStringConvertible.Type      //=> true
Int.self is CustomStringConvertible.Protocol  //=> false
```

Even without `P.Protocol`, we can test for equality:

```swift
Int.self is CustomStringConvertible.Type  //=> true
Int.self == CustomStringConvertible.self  //=> false
```

For protocols `P`, `P.self` returns a `P.Protocol`, not `P.Type`:

```swift
let metatype = CustomStringConvertible.self
print(type(of: metatype))  //=> CustomStringConvertible.Protocol
```

In practise, the existence of `P.Protocol` creates problems. If `T` is a generic parameter, then `T.Type` turns into `P.Protocol` if a protocol `P` is passed:

```swift
func printMetatype<T>(_ meta: T.Type) {
    print(dynamicType(meta))
    let copy = T.self
    print(dynamicType(copy))
}

printMetatype(CustomStringConvertible.self)  //=> CustomStringConvertible.Protocol x2
```

Lets review the following situation:

```swift
func isIntSubtype<T>(of: T.Type) -> Bool {
    return Int.self is T.Type
}

isIntSubtype(of: CustomStringConvertible.self)  //=> false
```

Now we understand that because `T` is a protocol `P`, `T.Type` turns into a `P.Protocol`, and we get the confusing behaviour.

Summing up issues with `P.Protocol`, it does not bring any additional functionality (we can test `.Type`s for `is` and for `==`),
but tends to appear unexpectedly and break subtyping with metatypes.

### Even more issues with `.Protocol`

> [1] When `T` is a protocol `P`, `T.Type` is the metatype of the protocol type itself, `P.Protocol`. `Int.self` is not `P.self`.
>
> [2] There isn't a way to generically expression `P.Type` **yet**.
>
> [3] The syntax would have to be changed in the compiler to get something that behaves like `.Type` today.
>
> Written by Joe Groff: [\[1\]](https://twitter.com/jckarter/status/754420461404958721) [\[2\]](https://twitter.com/jckarter/status/754420624261472256)  [\[3\]](https://twitter.com/jckarter/status/754425573762478080)

There is a workaround for `isIntSubtype` example above. If we pass a `P.Type.Type`, then it turns into `P.Type.Protocol`, but it is still represented with `.Type` in generic contexts. If we manage to drop outer `.Type`, then we get `P.Type`:

```swift
func isIntSubtype<T>(of _: T.Type) -> Bool {
  return Int.self is T   // not T.Type here anymore
}

isIntSubtype(of: CustomStringConvertible.Type.self) //=> true
```

In this call, `T = CustomStringConvertible.Type`. We can extend this issue and find the second problem by checking against the metatype of `Any`:

```swift
func isIntSubtype<T>(of _: T.Type) -> Bool {
	return Int.self is T
}

isIntSubtype(of: Any.Type.self) //=> true

isIntSubtype(of: Any.self)      //=> true
```

When using `Any`, the compiler does not require `.Type` and returns `true` for both variations.

The third issue shows itself when we try to check protocol relationship with another protocol. Currently, there is no way (that we know of) to solve this problem:

```swift
protocol Parent {}
protocol Child : Parent {}

func isChildSubtype<T>(of _: T.Type) -> Bool {
	return Child.self is T
}

isChildSubtype(of: Parent.Type.self) //=> false
```

We also believe that this issue is the reason why the current global functions `sizeof`, `strideof` and `alignof` make use of generic `<T>(_: T.Type)` declaration notation instead of `(_: Any.Type)`.

### Magical members

There were the following "magical" members of all types/instances:

* `.dynamicType`, which was replaced with `type(of:)` function by SE-0096.
* `.Type` and `.Protocol`, which we propose to remove, see below.
* `.Self`, which acts like an `associatedtype`.
* `.self`, which will be reviewed in a separate proposal.

The tendency is to remove "magical" members: with this proposal there will only be `.Self` (does not count) and `.self`.

Also, `.Type` notation works like a generic type, and giving it generic syntax seems to be a good idea (unification).

## Proposed solution

* Remove `P.Protocol` type without a replacement. `P.self` will never return a `P.Protocol`.
* Rename `T.Type` to `Metatype<T>`.
* Rename `type(of:)` function from SE-0096 to `metatype(of:)`.

## Impact on existing code

This is a source-breaking change that can be automated by a migrator. All occurrences of `T.Type` and `T.Protocol` will be changed to `Metatype<T>`. All usages of `type(of:)` will be changed to `metatype(of:)`

## Alternatives considered

* Rename `T.self` to `T.metatype`. However, this can be proposed separately.
* Use `Type<T>` instead of `Metatype<T>`. However, `Metatype` is more precise here.
