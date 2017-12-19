# Non-Exhaustive Enums

* Proposal: [SE-0192](0192-non-exhaustive-enums.md)
* Authors: [Jordan Rose](https://github.com/jrose-apple)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Active Review (December 19, 2017...January 3, 2018)**
* Implementation: [apple/swift#11961](https://github.com/apple/swift/pull/11961)
* Pre-review discussion: [Enums and Source Compatibility](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170807/038663.html), with additional [orphaned thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170911/039787.html)

<!--
*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

Currently, adding a new case to an enum is a source-breaking change, which is very inconvenient for library authors. This proposal aims to distinguish between enums that are _exhaustive_ (meaning they will never get any new cases) and those that are _non-exhaustive,_ and to ensure that clients handle any future cases when dealing with the latter. Some key notes:

- This only affects `public` enums.
- With rare exceptions, this does not affect `switch` statements in the same target as the enum.


## Motivation

It's well-established that many enums need to grow new cases in new versions of a library. For example, in last year's release of iOS 10, Foundation's [DateComponentsFormatter.UnitsStyle][] gained a `brief` case and UIKit's [UIKeyboardType][] gained an `asciiCapableNumberPad` case. Large error enums also often grow new cases to go with new operations supported by the library. This all implies that library authors *must* have a way to add new cases to enums.

At the same time, we really like that you can exhaustively switch over enums. This feature helps prevent bugs and makes it possible to enforce [definitive initialization][DI] without having `default` cases in every `switch`. So we don't want to get rid of enums where every case is known, either. This calls for a new annotation that can distinguish between exhaustive and non-exhaustive enums.

To see how this distinction will play out in practice, I investigated the public headers of Foundation in the macOS SDK. Out of all 60 or so `NS_ENUM`s in Foundation, only 6 of them are clearly exhaustive:

- [ComparisonResult](https://developer.apple.com/documentation/foundation/comparisonresult)
- [NSKeyValueChange](https://developer.apple.com/documentation/foundation/nskeyvaluechange) / [NSKeyValueSetMutationKind](https://developer.apple.com/documentation/foundation/nskeyvaluesetmutationkind)
- [NSRectEdge](https://developer.apple.com/documentation/foundation/nsrectedge)
- [FileManager.URLRelationship](https://developer.apple.com/documentation/foundation/filemanager.urlrelationship)
- *maybe* [Decimal.CalculationError](https://developer.apple.com/documentation/foundation/nsdecimalnumber.calculationerror)

...with a handful more that could go either way, such as [Stream.Status](https://developer.apple.com/documentation/foundation/stream.status). This demonstrates that there is a clear default for public enums, at least in Objective-C.

  [DateComponentsFormatter.UnitsStyle]: https://developer.apple.com/documentation/foundation/datecomponentsformatter.unitsstyle
  [UIKeyboardType]: https://developer.apple.com/documentation/uikit/uikeyboardtype
  [DI]: https://developer.apple.com/swift/blog/?id=28


## Proposed solution

In Swift 5, public enums can be declared as `@exhaustive`; public enums without this attribute are *non-exhaustive.*

When a client tries to switch over a non-exhaustive enum, they must include a `default` case unless the enum is declared in the same module as the switch. In Swift 4 mode, omitting this case will result in a warning; in Swift 5, it will be an error.

In Swift 4 mode, all public enums will implicitly be `@exhaustive` for source compatibility.

Enums imported from C will be non-exhaustive by default, with a new C-side annotation to make them `@exhaustive`. These enums conservatively always have the "cross-module" behavior.


## Detailed design

### Definition-side

```swift
@exhaustive public enum GregorianWeekday {
  case monday // ISO 8601 says weeks start on Monday
  case tuesday
  case wednesday
  case thursday
  case friday
  case saturday
  case sunday
}

// Defaults to "non-exhaustive" in Swift 5.
public enum HomeworkExcuse {
  case eatenByPet
  case thoughtItWasDueNextWeek
}
```

A public enum can now be declared `@exhaustive`. This attribute is implicitly added to public enums in Swift 4 mode; writing it explicitly is ignored. There is further discussion of these defaults in the "Default behavior" section below.

A warning is emitted when using `@exhaustive` on a non-public enum, since they have no effect within a module.

The naming and spelling of this annotation is discussed in the "Alternatives considered" section at the end of this proposal.


### Use-side

When a non-exhaustive enum defined in module A is used **from another module**, any switch statement that matches against it must include a catch-all case (either `default` or an "ignore" `_` pattern).

```swift
switch excuse {
case eatenByPet:
  // …
case thoughtItWasDueNextWeek:
  // …
}
```

In Swift 5, this would be an error. To maintain source compatibility, this would only produce a warning in Swift 4 mode. The Swift 4 program will trap at run time if an unknown enum case is actually encountered.

To simplify a common use case, enums from modules imported as `@testable` will always be treated as exhaustive as well.

All other uses of enums (`if case`, creation, accessing members, etc) do not change. Only the exhaustiveness checking of switches is affected by `@exhaustive`, and then only across module boundaries. Non-exhaustive switches over `@exhaustive` enums (and boolean values) will continue to be invalid in all language modes.

> Note: Once Swift supports cross-module inlinable functions, switch statements in such functions will also need to provide a catch-all case, even for non-exhaustive enums declared in the same module.

Here's a more complicated example:

```swift
switch (excuse, notifiedTeacherBeforeDeadline) {
case (.eatenByPet, true):
  // …
case (.thoughtItWasDueNextWeek, true):
  // …
case (_, false):
  // …
}
```

This switch handles all *known* patterns, but still doesn't account for the possibility of a new enum case when the second tuple element is `true`. This should be an error in Swift 5 and a warning in Swift 4, like the first example.

The consequences of losing exhaustiveness checking for non-exhaustive enums are discussed in the "Alternatives considered" section at the end of this proposal.

> A number of pre-reviewers have been concerned about the loss of exhaustiveness checking and the subsequent difficulty in updating to a new version of a dependency. In the original swift-evolution thread, Vladimir S. [describes the concerning scenario][scenario] in detail.

  [scenario]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20171002/040053.html


### Default behavior

Making "non-exhaustive" the default behavior was not a lightly-made decision. There are two obvious alternatives here: leave `@exhaustive` as the default, and have *no* default, at least in Swift 5 mode. An earlier version of this proposal went with the latter, but got significant pushback for making public enums more complicated than just adding `public`. This argues for having *some* default.

The use cases for public enums fall into three main categories:

| Use Case                       | Exhaustive                                                                                 | Non-exhaustive                                                                                 |
|--------------------------------|--------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| Multi-module app               | The desired behavior. Compiler can find all clients if the enum becomes non-exhaustive.    | Compiler can find all clients if the enum becomes exhaustive.                                  |
| Open-source library (SwiftPM)  | Changing to non-exhaustive is a source-breaking change; it produces errors in any clients. | Changing to exhaustive produces warnings in any clients.                                       |
| ABI-stable library (Apple OSs) | **Cannot** change to non-exhaustive; it would break binary compatibility.                  | Changing to exhaustive produces warnings in clients (probably dependent on deployment target). |

Although multi-module apps are likely responsible for most uses of `public`, they also provide the environment in which it is easiest to make changes, since both the "library" and the "client" are part of the same project. For actual libraries, "non-exhaustive" is a much better place to start; if it is a mistake, a minor release of the library can fix the issue without requiring immediate source changes in clients.

Defaulting to non-exhaustive in Swift 5 is effectively a language change from Swift 4, where all enums were treated as exhaustive. This does require care when manually migrating code from Swift 4 to Swift 5, or when copying existing example code from online into a Swift 5 module. However, this still only affects situations where an enum is (1) public and (2) switched over (3) from another module, and even when this *does* occur it is still reasonable to fix.

> This was one of the most controversial parts of the proposal. In the original swift-evolution thread, Rex Fenley [summarized the downsides][downsides] pretty well. Rather than present a simplified view of the concerns, I suggest reading his email directly.

  [downsides]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170918/039867.html


### C enums

Enums imported from C are a bit trickier, because it's difficult to tell whether they're part of the current project or not. An `NS_ENUM` in Apple's SDK should probably be treated as non-exhaustive, but one in your own framework might be exhaustive. Even there, though, it's possible that there's a "private case" defined in a .m file:

```objc
// MyAppPaperSupport.h
typedef NS_ENUM(NSInteger, PaperSize) {
  PaperSizeUSLetter = 0,
  PaperSizeA4 = 1,
  PaperSizePhoto4x6 = 2
};
```
```objc
// MyAppPaperSupport.m
static const PaperSize PaperSizeStickyNote = 255;
```

(While this pattern may be unfamiliar, it is used in Apple's SDKs, though not often.)

Therefore, enums imported from C will be treated conservatively: an otherwise-unannotated `NS_ENUM` will be imported as non-exhaustive and treated as such in all contexts. The newly-added C attribute `enum_extensibility` can be used to override this behavior:

```objc
typedef NS_ENUM(NSInteger, GregorianMonth) {
  GregorianMonthJanuary = 1,
  GregorianMonthFebruary,
  GregorianMonthMarch,
  GregorianMonthApril,
  GregorianMonthMay,
  GregorianMonthJune,
  GregorianMonthJuly,
  GregorianMonthAugust,
  GregorianMonthSeptember,
  GregorianMonthOctober,
  GregorianMonthNovember,
  GregorianMonthDecember,
} __attribute__((enum_extensibility(closed)));
```

Apple doesn't speak about future plans for its SDKs, so having an alternate form of `NS_ENUM` that includes this attribute is out of scope for this proposal.

This change will affect code *even in Swift 4 mode* (although it will only produce warnings there), so to ease the transition otherwise-unannotated C enums will continue to be `@exhaustive` until Swift 5 is released. That is, all Swift 4.x compilers will treat unannotated `NS_ENUM` declarations as exhaustive; a Swift 5 compiler with a Swift 4 mode will treat them as non-exhaustive.

Apart from the effect on switches, an imported `@exhaustive` enum's `init(rawValue:)` will also enforce that the case is one of those known at compile time. Imported non-exhaustive enums will continue to perform no checking on the raw value.

> This section only applies to enums that Swift considers "true enums", rather than option sets or funny integer values. In the past, the only way to get this behavior was to use the `NS_ENUM` or `CF_ENUM` macros, but the presence of `enum_extensibility(closed)` *or* `enum_extensibility(open)` will instruct Swift to treat the enum as a "true enum". Similarly, the newly-added `flag_enum` C attribute can be used to signify an option set like `NS_OPTIONS`.


## Comparison with other languages

"Enums", "unions", "variant types", "sum types", or "algebraic data types" are present in a number of other modern languages, most of which don't seem to treat this as an important problem.


### Languages without non-exhaustive enums

**Haskell** and **OCaml** make heavy use of enums ("algebraic data types", or just "types") without any feature like this; adding a new "case" is always a source-breaking change. (Neither of these languages seems to care much about binary compatibility.) This is definitely a sign that you can have a successful language without a form of non-exhaustive enum other than "protocols". **Kotlin** also falls in this bucket, although it uses enums ("enum classes") less frequently.

The **C#** docs have a nice section on [how the language isn't very helpful][c-sharp] for distinguishing exhaustive and non-exhaustive enums. **Objective-C**, of course, is in the same bucket, though Apple could start doing things with the `enum_extensibility` Clang attribute that was recently added.

  [c-sharp]: https://docs.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/enum#robust-programming


### Languages with alternate designs

**F#** enums ("unions") [either expose all of their "cases" or none of them][f-sharp]. The Swift equivalent of this would be not allowing you to switch on such an enum at all, as if it were a struct with private fields.

Enums in **D** are like enums in C, but D distinguishes `switch` from `final switch`, and only the latter is exhaustive. That is, it's a client-side decision at the use site, rather than a decision by the definer of the enum.


  [f-sharp]: https://docs.microsoft.com/en-us/dotnet/fsharp/language-reference/signatures


### Languages with designs similar to this proposal

**Rust** has an [accepted proposal][rust] to add non-exhaustive enums that looks a lot like this one, but where "exhaustive" is still the default to not break existing Rust programs. (There are some interesting differences that come up in Rust but not Swift; in particular they need a notion of non-exhaustive structs because their structs can be decomposed in pattern-matching as well.)

  [rust]: https://github.com/rust-lang/rfcs/blob/master/text/2008-non-exhaustive.md



## Source compatibility

It is now a source-compatible change to add a case to a non-exhaustive enum.

It is still not a source-compatible change to remove a case from an enum (exhaustive or non-exhaustive).

It is a source-compatible change to change a non-exhaustive enum into an exhaustive enum, but not vice versa.


## Effect on ABI stability

Currently, the layout of a public enum is known at compile time in both the defining library and in its clients. For a library concerned about binary compatibility, the layout of a non-exhaustive enum must not be exposed to clients, since the library may choose to add a new case that does not fit in that layout in its next release.

This change does not affect the layout of `@objc` enums, which always have the same representation as a similarly-defined C enum. (Note that the representation of a non-`@objc` enum's case may differ from its raw value; this improves the efficiency of `switch` statements when all cases are known at compile time.)

These considerations should not affect libraries shipped with their clients, including SwiftPM packages. In these cases, the compiler is always free to optimize based on the layout of an enum because the library won't change.


## Effect on Library Evolution

It is now a binary-compatible change to add a case to a non-exhaustive enum.

It is still not a binary-compatible change to remove a case from an enum (exhaustive or non-exhaustive).

It is not a binary-compatible change to add `@objc` to an enum, nor to remove it.

Taking an existing non-exhaustive enum and making it exhaustive is something we'd like to support without breaking binary compatibility, but there is no design for that yet. The reverse will not be allowed.


## Future direction: non-public cases

The work required for non-exhaustive enums also allows for the existence of non-public cases in a public enum. This already shows up in practice in Apple's SDKs, as described briefly in the section on "C enums" above. Like "enum inheritance", this kind of behavior can mostly be emulated by using a second enum inside the library, but that's not sufficient if the non-public values need to be vended opaquely to clients.


## Future direction: compatibility checking

Of course, the compiler can't stop a library author from adding a new case to a non-exhaustive enum, even though that will break source and binary compatibility. We already have two ideas on how we could catch mistakes of this nature:

- A checker that can compare APIs across library versions, using swiftmodule files or similar.

- Encoding the layout of a type in a symbol name. Clients could link against this symbol so that they'd fail to launch if it changes, but even without that an automated system could check the list of exported symbols to make sure nothing was removed.

Exhaustive enums remain useful even without any automated checking, and such checking should account for more than just enums, so it's not being included in this proposal.


## Future direction: efficient representation of enums with raw types

For enums with raw types, a 32-bit integer can be used as the representation rather than a fully opaque value, on the grounds that 4 billion is a reasonable upper limit for the number of distinct cases in an enum without payloads. However, this would make it an ABI-breaking change to add or remove a raw type from an enum, and would make the following definitions not equivalent:

```swift
/* non-exhaustive */ public enum HTTPMethod: String {
  case get = "GET"
  case put = "PUT"
  case post = "POST"
  case delete = "DELETE"
}
```

```swift
/* non-exhaustive */ public enum HTTPMethod: RawRepresentable {
  case get
  case put
  case post
  case delete

  public init?(rawValue: String) {
    switch rawValue {
    case "GET": return .get
    case "PUT": return .put
    case "POST": return .post
    case "DELETE": return .delete
    default: return nil
    }
  }

  public var rawValue: String {
    switch self {
    case .get: return "GET"
    case .put: return "PUT"
    case .post: return "POST"
    case .delete: return "DELETE"
    }
  }
}
```

As such, this representation change is out of scope for this proposal.


## Alternatives considered

### Syntax

#### Naming: "closed" and "open"

The original description of the problem used "closed" and "open" to describe exhaustive and non-exhaustive enums, respectively. However, this conflicts with the use of `open` in classes and their members. In this usage, `open` is clearly a greater level of access than `public`, in that clients of an `open` class can do everything they can with a `public` class and more; it is source-compatible to turn a `public` class into an `open` one. For enums, however, it is exhaustive enums that are "greater": you can do everything you can with a non-exhaustive enum and more, and it is source-compatible to turn a non-exhaustive enum into an exhaustive one (at the cost of a warning).


#### Naming: Other options

Several more options were suggested during initial discussions:

- `complete` ("incomplete")
- `covered` (?)
- **`exhaustive`** (non-exhaustive)
- `nonextensible` (?)
- `final` (non-final)
- `finite` (non-finite, not "infinite")
- `fixed` (?)
- `locked` (?)
- `sealed` (non-sealed)
- `total` (partial)

I don't have a strong preference for any particular choice as long as it *isn't* "closed" / "open", for the reasons described above. I picked `exhaustive` because it matches the name proposed [in Rust][rust], but it is a little long. (Unfortunately, Clang's `enum_extensibility` attribute, recently added by us at Apple, uses `open` and `closed`.)

Note that "nonextensible" does have one problem: Apple already uses [`NS_TYPED_EXTENSIBLE_ENUM `][NS_TYPED_EXTENSIBLE_ENUM] to refer to enum-like sets of constants (usually strings) that *clients* can add "cases" to. That's not the same meaning as the exhaustiveness discussed in this proposal.

  [NS_TYPED_EXTENSIBLE_ENUM]: https://developer.apple.com/library/content/documentation/Swift/Conceptual/BuildingCocoaApps/InteractingWithCAPIs.html#//apple_ref/doc/uid/TP40014216-CH8-ID206


#### Modifier or attribute?

This proposal suggests a new *attribute* for enums, `@exhaustive`; it could also be a modifier `exhaustive`, implemented as a context-sensitive keyword. The original version of the proposal went with a modifier because most attributes only affect the *definition* of an API, not its use, but in preliminary discussions the core team felt that an attribute was a better fit.


#### Annotation or member?

In addition to the attribute approach detailed in this proposal, discussion on swift-evolution also suggested mirroring the form of a `switch` statement by using an additional kind of declaration inside an enum:

```swift
public enum HomeworkExcuse {
  case eatenByPet
  case thoughtItWasDueNextWeek
  default // NEW
}
```

`continue` and `final` were also suggested for this additional declaration. I'm not inherently against this approach, but it does seem a little harder to spot when looking at the generated interface for a library. In preliminary discussions, the core team was not particularly fond of this approach, however.


### Preserve exhaustiveness diagnostics for non-exhaustive enums

In the initial discussion, multiple people were unhappy with the loss of compiler warnings for switches over non-exhaustive enums that comes with using `default`—they wanted to be able to handle all cases that exist today, and have the compiler tell them when new ones were added. Ultimately I decided not to include this in the proposal with the expectation is that switches over non-exhaustive enums should be uncommon.

There were two suggestions for this, described below. Both are additive features that could be added to the language later even if we decide to leave them out now.

#### `future` cases

```swift
switch excuse {
case .eatenByPet:
  // …
case .thoughtItWasDueNextWeek:
  // …
future:
  // …
}
```

Like `default`, the `future` case would be executed if none of the other cases match; unlike `default`, the compiler would still warn you if you failed to account for all existing cases. However, this results in some of your code being *impossible to test,* since you can't write a test that passes an unknown value to this switch. This may be true in practice with a `default` case, but it's not expected to be the common case for non-exhaustive enums. The expectation is that switches over non-exhaustive enums are uncommon.

(It's also unclear how this would work with switches over more complicated patterns, although it seems reasonable to limit it to matching a single enum value.)


#### `switch!`

```swift
switch! excuse {
case .eatenByPet:
  // …
case .thoughtItWasDueNextWeek:
  // …
}
```

`switch!` is a more limited form than `future`, which does not support any action other than trapping when the enum is not one of the known cases. This avoids some of the problems with `future` (such as making it much less important to test), but isn't exactly in the spirit of non-exhaustive enums, where you *know* there will be more cases in the future. It's also still added complexity for the language.


### Testing invalid cases

Another issue with non-exhaustive enums is that clients cannot properly test what happens when a new case is introduced, almost by definition. Brent Royal-Gordon came with the idea to have a new type annotation that would allow the creation of an invalid enum value. Since this is only something to use for testing, the initial version of the idea used `@testable` as the spelling for the annotation. The tests could then use a special expression, `#invalid`, to pass this invalid value to a function with a `@testable` enum parameter.

However, this would only work in cases where the action to be taken does not actually depend on the enum value. If it needs to be passed to the original library that owns the enum, or used with an API that is not does not have this annotation, the code still cannot be tested properly.

```swift
override func process(_ transaction: @testable Transaction) {
  switch transaction {
  case .deposit(let amount):
    // …
  case .withdrawal(let amount):
    // …
  default:
    super.process(transaction) // hmm…
  }
}
```

This is an additive feature, so we can come back and consider it in more detail even if we leave it out of the language for now. Meanwhile, the effect can be imitated using an Optional or ImplicitlyUnwrappedOptional parameter.


### Non-exhaustive enums in Swift 4 mode

This proposal provides no way to declare non-exhaustive enums in Swift 4 mode. We would need to introduce a new attribute (`@nonexhaustive`) to allow that. Since we expect people to move projects to Swift 5 over time, however, this isn't a long-term concern. Not every new feature needs to be available in Swift 4 mode, and the proposal is simpler without a negative attribute.


### "Can there be a kind of open enum where you can add new cases in extensions?"

There is no push to allow adding new cases to an enum from *outside* a library. This use case (no pun intended) is more appropriate for a RawRepresentable struct, where the library defines some initial values as static properties. (You can already switch over struct values in Swift as long as they are Equatable.)
