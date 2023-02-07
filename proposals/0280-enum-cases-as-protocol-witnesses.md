# Enum cases as protocol witnesses

* Proposal: [SE-0280](0280-enum-cases-as-protocol-witnesses.md)
* Author: [Suyash Srijan](https://github.com/theblixguy)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented (Swift 5.3)**
* Implementation: [apple/swift#28916](https://github.com/apple/swift/pull/28916)
* Bug: [apple/swift#45758](https://github.com/apple/swift/issues/45758)
* Toolchain: [macOS](https://ci.swift.org/job/swift-PR-toolchain-osx/477/artifact/branch-master/swift-PR-28916-477-osx.tar.gz) & [Linux](https://ci.swift.org/job/swift-PR-toolchain-Linux/346/artifact/branch-master/swift-PR-28916-346-ubuntu16.04.tar.gz)
* Review: ([1](https://forums.swift.org/t/se-0280-enum-cases-as-protocol-witnesses/34257)) ([Acceptance](https://forums.swift.org/t/acceepted-se-0280-enum-cases-as-protocol-witnesses/34850))

## Introduction

The aim of this proposal is to lift an existing restriction, which is that enum cases cannot participate in protocol witness matching.

Swift-evolution thread: [Enum cases as protocol witnesses](https://forums.swift.org/t/enum-cases-as-protocol-witnesses/32753)

## Motivation

Currently, Swift has a very restrictive protocol witness matching model where a protocol witness has to match _exactly_ with the requirement, with some exceptions (see [Protocol Witness Matching Manifesto](https://forums.swift.org/t/protocol-witness-matching-mini-manifesto/32752)).

For example, if one writes a protocol with static requirements:

```swift
protocol DecodingError {
  static var fileCorrupted: Self { get }
  static func keyNotFound(_ key: String) -> Self
}
```

and attempts to conform an enum to it, then writing a case with the same name (and arguments) is not considered a match:

```swift
enum JSONDecodingError: DecodingError {
  case fileCorrupted // error, because it is not a match
  case keyNotFound(_ key: String) // error, because it is not a match
}
```

This is quite surprising, because even though cases are not _written_ as a `static var` or `static func`, they do _behave_ like one both syntactically and semantically throughout the language. For example:

```swift
enum Foo {
  case bar(_ value: Int)
  case baz
}

let f = Foo.bar // `f` is a function of type (Int) -> Foo
let bar = f(2) // Returns Foo
let baz = Foo.baz // Returns Foo
```

is the same as:

```swift
struct Foo {
  static func bar(_ value: Int) -> Self { ... }
  static var baz: Self { ... }
}

let f = Foo.bar // `f` is a function of type (Int) -> Foo
let bar = f(2) // Returns Foo
let baz = Foo.baz // Returns Foo
```

Such "spelling" exceptions exist when matching other kinds of requirements as well, for example:

```swift
protocol Foo {
  var somePropertyA: Self { get }
}

struct ImplementsFoo: Foo {
  // This can be a 'let' because even though the
  // keywords don't match, and a variable and a 
  // constant are two different things, the
  // *semantics* of 'var ... { get }' and 'let'
  // do match.
  let somePropertyA: Self
  // and you can write it as a 'var' if you want 
  // and still keep the semantics the same.
  var somePropertyA: Self
}
```

Now, because enum cases are not considered as a "witness" for static protocol requirements, one has to provide a manual implementation instead:

```swift
enum JSONDecodingError: DecodingError {
  case _fileCorrupted
  case _keyNotFound(_ key: String)
  static var fileCorrupted: Self { return ._fileCorrupted }
  static func keyNotFound(_ key: String) -> Self { 
    return ._keyNotFound(key) 
  }
}
```

This leads to some rather unfortunate consequences:

1. The ability to write a case with the same name as the requirement is lost. Now, you can rename the case to something different, but it might not always be ideal, especially because naming things right is a really hard problem. In most cases, you expect the case to be named the same as the requirement.
2. The namespace of the enum is now polluted with both cases and requirements (for example, in the snippet above we have `_fileCorrupted` and `fileCorrupted`), which can be confusing during code completion.
3. There's extra code that now has to be maintained and which arguably should not exist in the first place.

In almost every corner of the language, enum cases and static properties/functions are indistinguishable from each other, *except* when it comes to matching protocol requirements, which is very inconsistent, so it is not unreasonable to think of a enum case without associated values as a `static`, get-only property that returns `Self` or an enum case with associated values as a `static` function (with arguments) that returns `Self`.

Lifting this restriction can also lead to other improvements, for example, one can conform `DispatchTimeInterval` directly to Combine's `SchedulerTypeIntervalConvertible` instead of having to go through a much more complicated type like `DispatchQueue.SchedulerTimeType.Stride`:

```swift
extension DispatchTimeInterval: SchedulerTimeIntervalConvertible {
  public static func seconds(_ s: Double) -> Self { 
    return DispatchTimeInterval.seconds(Int((s * 1000000000.0).rounded())) 
  }
  // Remaining requirements already satisfied by cases
}
```

## Proposed Solution

The current restriction is lifted and the compiler allows a static protocol requirement to be witnessed by an enum case, under the following rules:

1. A static, get-only protocol requirement having an enum type or `Self` type can be witnessed by an enum case with no associated values.
2. A static function requirement with arguments and returning an enum type or `Self` type can be witnessed by an enum case with associated values having the same argument list as the function's.

This means the example from the motivation section will successfully compile:

```swift
enum JSONDecodingError: DecodingError {
  case fileCorrupted // okay
  case keyNotFound(_ key: String) // okay
}
```

This also means the mental model of an enum case will now be _more_ consistent with static properties/methods and an inconsistency in the language will be removed. 

You will still be able to implement the requirement manually if you want and code that currently compiles today (with the manual implementation) will continue to compile. However, you will now have the option to let the case satisfy the requirement directly.

Here are a few more examples that demonstrate how cases will be matched with the requirements:

```swift
protocol Foo {
  static var zero: FooEnum { get }
  static var one: Self { get }
  static func two(arg: Int) -> FooEnum
  static func three(_ arg: Int) -> Self
  static func four(_ arg: String) -> Self
  static var five: Self { get }
  static func six(_: Int) -> Self
  static func seven(_ arg: Int) -> Self
  static func eight() -> Self
}

enum FooEnum: Foo {
  case zero // okay
  case one // okay
  case two(arg: Int) // okay
  case three(_ arg: Int) // okay
  case four(arg: String) // not a match
  case five(arg: Int) // not a match
  case six(Int) // okay
  case seven(Int) // okay
  case eight // not a match
}
```

The last one is intentional - there is no way to declare a `case eight()` today (and even when you could in the past, it actually had a different type). In this case, the requirement `static func eight()` can in fact be better expressed as a `static var eight`. In the future, this limitation may be lifted when other kinds of witness matching is considered.

## Source compatibility

This does not break source compatibility since it's a strictly additive change and allows code that previously did not compile to now compile and run successfully.

## Effect on ABI stability

This does not affect the ABI and does not require new runtime support.

## Effect on API resilience

Switching between enum cases and static properties/methods is not a resilient change due to differences in ABI and mangling. Doing so will break binary compatibility, or source compatibility if clients are pattern matching on the cases for example.


## Alternatives considered

- Allow protocol requirements to be declared as `case` instead of `static var` or `static func` - the obvious downside of doing this would be that only enums would be able to adopt such a protocol, which would be unreasonably restrictive because other types like classes and structs having satisfying witnesses would no longer be able to adopt such a protocol.
- Only allow enum cases without associated values to participate out of the box. Ones with associated values will be disallowed unless explicitly marked with a specific annotation to allow them to be used as "factories". It seems unnecessarily restrictive to impose another syntactic barrier, one which does not exist in other types. The semantics of a protocol requirement is up to the author to document and for clients to read and verify before implementing, so adding another annotation does not provide any language improvements.
- Leave the existing behaviour as-is.

## Future directions

We can allow for more kinds of witness matching, as described in the [Protocol Witness Matching Manifesto](https://forums.swift.org/t/protocol-witness-matching-mini-manifesto/32752), such as subtyping and default arguments.
