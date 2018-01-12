# Frozen and Non-frozen Enums

* Proposal: [SE-0192](0192-non-exhaustive-enums.md)
* Authors: [Jordan Rose](https://github.com/jrose-apple)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Returned for revision**
* Implementation: [apple/swift#11961](https://github.com/apple/swift/pull/11961)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/a773d07ff4beab8b7855adf0ac56d1e13bb7b44c/proposals/0192-non-exhaustive-enums.md)
* Pre-review discussion: [Enums and Source Compatibility](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170807/038663.html), with additional [orphaned thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170911/039787.html)
* Review discussion: [Review author summarizes some feedback from review discussion and proposes alternatives](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20180101/042480.html)

<!--
*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

Currently, adding a new case to an enum is a source-breaking change, which is very inconvenient for library authors. This proposal aims to distinguish between enums that are _frozen_ (meaning they will never get any new cases) and those that are _non-frozen,_ and to ensure that clients handle any future cases when dealing with the latter. Some key notes:

- This only affects `public` enums.
- With rare exceptions, this does not affect `switch` statements in the same target as the enum.


### Differences from the first revision

- `unknown case` has been added, to preserve exhaustivity checking
- The name of the attribute is now `@frozen` rather than `@exhaustive`
- The proposal now describes what will happen if you "break the contract" in a new library version
- Much more discussion of future directions and alternatives considered

Thanks to everyone who offered feedback!


## Motivation

It's well-established that many enums need to grow new cases in new versions of a library. For example, in last year's release of iOS 10, Foundation's [DateComponentsFormatter.UnitsStyle][] gained a `brief` case and UIKit's [UIKeyboardType][] gained an `asciiCapableNumberPad` case. Large error enums also often grow new cases to go with new operations supported by the library. This all implies that library authors *must* have a way to add new cases to enums.

At the same time, we really like that you can exhaustively switch over enums. This feature helps prevent bugs and makes it possible to enforce [definitive initialization][DI] without having `default` cases in every `switch`. So we don't want to get rid of enums where every case is known, either. This calls for a new annotation that can distinguish between enums where every case can be known statically and enums that might grow new cases in the future, which will be applied to enums defined in Swift as well as those imported from C and Objective-C.

To see how this distinction will play out in practice, I investigated the public headers of Foundation in the macOS SDK. Out of all 60 or so `NS_ENUM`s in Foundation, only 6 of them are clearly intended to be switched exhaustively:

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

In Swift 5, public enums can be declared as `@frozen`; public enums without this attribute are *non-frozen.* (Grammatical note: they are not "unfrozen" because that implies that they were frozen at one point.)

When a client tries to switch over a non-frozen enum, they must include either a `default` case or a new `unknown` case unless the enum is declared in the same module as the switch. (This is only relevant across module boundaries because otherwise the compiler knows that the developer is able to update all use sites.) In Swift 4 mode, omitting this case will result in a warning; in Swift 5, it will be an error.

In Swift 4 mode, all public enums will implicitly be `@frozen` for source compatibility.

Enums imported from C will be non-frozen by default, with a new C-side annotation to make them `@frozen`. These enums conservatively always have the "cross-module" behavior.


## Detailed design

### Definition-side

```swift
@frozen public enum GregorianWeekday {
  case monday // ISO 8601 says weeks start on Monday
  case tuesday
  case wednesday
  case thursday
  case friday
  case saturday
  case sunday
}

// Defaults to "non-frozen" in Swift 5.
public enum HomeworkExcuse {
  case eatenByPet
  case thoughtItWasDueNextWeek
}
```

A public enum can now be declared `@frozen`. This attribute is implicitly added to public enums in Swift 4 mode; writing it explicitly is ignored. There is further discussion of these defaults in the "Default behavior" section below.

A warning is emitted when using `@frozen` on a non-public enum, since it has no effect within a module.

The naming and spelling of this annotation is discussed in the "Alternatives considered" section at the end of this proposal.


### Use-side

When a non-frozen enum defined in module A is used **from another module**, any switch statement that matches against it must include a catch-all case (`default`, an "ignore" `_` pattern, or the new `unknown` case described below).

```swift
switch excuse {
case .eatenByPet:
  // …
case .thoughtItWasDueNextWeek:
  // …
}
```

In Swift 5, this would be an error. To maintain source compatibility, this would only produce a warning in Swift 4 mode. The Swift 4 program will trap at run time if an unknown enum case is actually encountered.

To simplify a common use case, enums from modules imported as `@testable` will always be treated as frozen as well.

All other uses of enums (`if case`, creation, accessing members, etc) do not change. Only the exhaustiveness checking of switches is affected by `@frozen`, and then only across module boundaries. Non-exhaustive switches over `@frozen` enums (and boolean values) will continue to be invalid in all language modes.

> Note: Once Swift supports cross-module inlinable functions, switch statements in such functions will also need to provide a catch-all case, even for non-frozen enums declared in the same module.

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


### `unknown case`

The downside of using a `default` case is that the compiler can no longer alert a developer that a particular enum has elements that aren't explicitly handled in the `switch`. To remedy this, `switch` will be augmented with a new kind of case, spelled `unknown case`. 

```swift
switch excuse {
case .eatenByPet:
  // …
case .thoughtItWasDueNextWeek:
  // …
unknown case:
  // …
}
```

Like `default`, `unknown case` matches any value. However, unlike `default` (and the "ignore" pattern `_`), the compiler will produce a *warning* if all known elements of the enum have not already been matched. This is a warning rather than an error so that adding new elements to the enum remains a source-compatible change. (This is also why `unknown case` matches any value rather than just those not seen at compile-time.)

`unknown case` must be the last case in a `switch`. This is not strictly necessary, but it is consistent with `default`. This restriction is discussed further in the "`unknown case` patterns" section under "Future directions".

The compiler will warn if the enum being matched by `unknown case` is `@frozen`. This is a warning rather than an error so that adding `@frozen` to the enum remains a source-compatible change. It is an error to use `unknown case` with a non-enum-typed value.

A `switch` may not have both a `default` case and an `unknown case`. Since both patterns match any value, whichever pattern was written first would be chosen, making the other unreachable. This restriction is discussed further under "Alternatives considered".

`unknown case` has a downside that it is not testable, since there is no way to create an enum value that does not match any known cases, and there wouldn't be a safe way to use it if there was one. However, combining `unknown case` with other cases using `fallthrough` can get the effect of following another case's behavior while still getting compiler warnings for new cases.

```swift
switch excuse {
case .eatenByPet:
  showCutePicturesOfPet()

case .thoughtItWasDueNextWeek:
  fallthrough
unknown case:
  askForDueDateExtension()
}
```

The name `unknown case` was chosen not conflict with any existing valid Swift code. Discussion of the naming for this case is included at the end of the proposal under "Alternatives Considered".


### Default behavior

Making "non-frozen" the default behavior was not a lightly-made decision. There are two obvious alternatives here: leave `@frozen` as the default, and have *no* default, at least in Swift 5 mode. An early version of this proposal went with the latter, but got significant pushback for making public enums more complicated than just adding `public`. This argues for having *some* default.

The use cases for public enums fall into three main categories:

| Use Case                       | Frozen                                                                                 | Non-frozen                                                                                 |
|--------------------------------|----------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| Multi-module app               | The desired behavior. Compiler can find all clients if the enum becomes non-frozen.    | Compiler can find all clients if the enum becomes frozen.                                  |
| Open-source library (SwiftPM)  | Changing to non-frozen is a source-breaking change; it produces errors in any clients. | Changing to frozen produces warnings in any clients.                                       |
| ABI-stable library (Apple OSs) | **Cannot** change to non-frozen; it would break binary compatibility.                  | Changing to frozen produces warnings in clients (probably dependent on deployment target). |

Although multi-module apps are likely responsible for most uses of `public`, they also provide the environment in which it is easiest to make changes, since both the "library" and the "client" are part of the same project. For actual libraries, "non-frozen" is a much better place to start; if it is a mistake, a minor release of the library can fix the issue without requiring immediate source changes in clients.

Defaulting to non-frozen in Swift 5 is effectively a language change from Swift 4, where all enums were treated as frozen. This does require care when manually migrating code from Swift 4 to Swift 5, or when copying existing example code from online into a Swift 5 module. However, this still only affects situations where an enum is (1) public and (2) switched over (3) from another module, and even when this *does* occur it is still reasonable to fix.

> This was one of the most controversial parts of the proposal. In the original swift-evolution thread, Rex Fenley [summarized the downsides][downsides] pretty well. Rather than present a simplified view of the concerns, I suggest reading his email directly.

  [downsides]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170918/039867.html


### C enums

Enums imported from C are a bit trickier, because it's difficult to tell whether they're part of the current project or not. An `NS_ENUM` in Apple's SDK should probably be treated as non-frozen, but one in your own framework might be frozen. Even there, though, it's possible that there's a "private case" defined in a .m file:

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

Therefore, enums imported from C will be treated conservatively: an otherwise-unannotated `NS_ENUM` will be imported as non-frozen and treated as such in all contexts. The newly-added C attribute `enum_extensibility` can be used to override this behavior:

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

This change will affect code *even in Swift 4 mode* (although it will only produce warnings there), so to ease the transition otherwise-unannotated C enums will continue to be `@frozen` until Swift 5 is released. That is, all Swift 4.x compilers will treat unannotated `NS_ENUM` declarations as frozen; a Swift 5 compiler with a Swift 4 mode will treat them as non-frozen.

Apart from the effect on switches, an imported `@frozen` enum's `init(rawValue:)` will also enforce that the case is one of those known at compile time. Imported non-frozen enums will continue to perform no checking on the raw value.

> This section only applies to enums that Swift considers "true enums", rather than option sets or funny integer values. In the past, the only way to get this behavior was to use the `NS_ENUM` or `CF_ENUM` macros, but the presence of `enum_extensibility(closed)` *or* `enum_extensibility(open)` will instruct Swift to treat the enum as a "true enum". Similarly, the newly-added `flag_enum` C attribute can be used to signify an option set like `NS_OPTIONS`.


## Comparison with other languages

"Enums", "unions", "variant types", "sum types", or "algebraic data types" are present in a number of other modern languages, most of which don't seem to treat this as an important problem.


### Languages without non-frozen enums

**Haskell** and **OCaml** make heavy use of enums ("algebraic data types", or just "types") without any feature like this; adding a new "case" is always a source-breaking change. (Neither of these languages seems to care much about binary compatibility.) This is definitely a sign that you can have a successful language without a form of non-frozen enum other than "protocols". **Kotlin** also falls in this bucket, although it uses enums ("enum classes") less frequently.

The **C#** docs have a nice section on [how the language isn't very helpful][c-sharp] for distinguishing frozen and non-frozen enums. **Objective-C**, of course, is in the same bucket, though Apple could start doing things with the `enum_extensibility` Clang attribute that was recently added.

  [c-sharp]: https://docs.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/enum#robust-programming


### Languages with alternate designs

**F#** enums ("unions") [either expose all of their "cases" or none of them][f-sharp]. The Swift equivalent of this would be not allowing you to switch on such an enum at all, as if it were a struct with private fields.

Enums in **D** are like enums in C, but D distinguishes `switch` from `final switch`, and only the latter is exhaustive. That is, it's a client-side decision at the use site, rather than a decision by the definer of the enum.

**Scala** has enums, but the pattern most people seem to use is "sealed traits", which in Swift terms would be "protocols where all conforming types are known, usually singletons". A non-frozen enum would then just be a normal protocol. Some downsides of applying this to Swift are discussed below under "Use protocols instead".

  [f-sharp]: https://docs.microsoft.com/en-us/dotnet/fsharp/language-reference/signatures


### Languages with designs similar to this proposal

**Rust** has an [accepted proposal][rust] to add non-frozen enums that looks a lot like this one, but where "frozen" is still the default to not break existing Rust programs. (There are some interesting differences that come up in Rust but not Swift; in particular they need a notion of non-frozen structs because their structs can be decomposed in pattern-matching as well.)

  [rust]: https://github.com/rust-lang/rfcs/blob/master/text/2008-non-exhaustive.md



## Source compatibility

It is now a source-compatible change to add a case to a public non-frozen enum.

It is still not a source-compatible change to remove a case from a public enum (frozen or non-frozen).

It is a source-compatible change to change a non-frozen enum into a frozen enum, but not vice versa.


### Breaking the contract

If a library author adds a case to an enum marked `@frozen`, any existing switches will likely not handle this new case. The compiler will produce an error for any such switch (i.e. those without a `default` case or `_` pattern to match the enum value), noting that the case is unhandled; this is the same error that is produced for a non-exhaustive switch in Swift 4.

If a library author removes `@frozen` from an enum previously marked `@frozen`, the compiler will likewise produce an error for any switch that does not have a `default` case or `_` pattern, noting that it needs either a `default` case or `unknown case`. This is the same error that people will see when porting code from Swift 4 to Swift 5, so it needs to explain the issue clearly and offer a clear recommendation of what to do.


## Effect on ABI stability

Currently, the layout of a public enum is known at compile time in both the defining library and in its clients. For a library concerned about binary compatibility, the layout of a non-frozen enum must not be exposed to clients, since the library may choose to add a new case that does not fit in that layout in its next release.

This change does not affect the layout of `@objc` enums, which always have the same representation as a similarly-defined C enum. (Note that the representation of a non-`@objc` enum's case may differ from its raw value; this improves the efficiency of `switch` statements when all cases are known at compile time.)

These considerations should not affect libraries shipped with their clients, including SwiftPM packages. In these cases, the compiler is always free to optimize based on the layout of an enum because the library won't change.


## Effect on Library Evolution

It is now a binary-compatible change to add a case to a public non-frozen enum.

It is still not a binary-compatible change to remove a case from a public enum (frozen or non-frozen).

It is not a binary-compatible change to add `@objc` to an enum, nor to remove it.

Taking an existing non-frozen enum and making it frozen is something we'd like to support without breaking binary compatibility, but there is no design for that yet. The reverse will not be allowed.


### Breaking the contract

Because the compiler uses the set of cases in a frozen enum to determine its in-memory representation and calling convention, adding a new case or removing `@frozen` from an enum in a library will result in "undefined behavior" from any client apps that have not been recompiled. This means a loss of memory-safety and type-safety on par with a misuse of "unsafe" types, which would most likely lead to crashes but could lead to code unexpectedly being executed or skipped. In short, things would be very bad.

Some ideas for how to prevent library authors from breaking the rules accidentally are discussed in "Compatibility checking" under "Future directions".


## Future directions

### `unknown case` patterns

As described, `unknown case` can only be used when switching over a single enum value; it does not work when trying to match a tuple element, or another enum's associated type. In theory, we could make a new *pattern* kind that allows matching unknown cases anywhere within a larger pattern:

```swift
switch (excuse, notifiedTeacherBeforeDeadline) {
case (.eatenByPet, true):
  // …
case (.thoughtItWasDueNextWeek, true):
  // …
case (unknown case, true):
  // …
case (_, false):
  // …
}
```

However, I'm not quite sure how the exhaustivity checking falls out here. In the following code, which case is chosen for `(.thoughtItWasDueNextWeek, true)`?

```swift
switch (excuse, notifiedTeacherBeforeDeadline) {
case (.eatenByPet, true): // 1
  // …
case (unknown case, true): // 2
  // …
case (_, false): // 3
  // …
case (.thoughtItWasDueNextWeek, _): // 4
  // …
}
```

- Case 2 is plausible because `unknown case` will catch any cases that aren't accounted for in the switch (in order to preserve source stability), and `.thoughtItWasDueNextWeek` hasn't been accounted for *yet.* This makes case 4 unreachable, which had better show up in a compiler warning.

- Case 4 is also plausible because `.thoughtItWasDueNextWeek` is clearly mentioned in the switch, and therefore it's not "unknown". This is probably what the user intended, but would be much more difficult to implement, and runs into the same trouble as mixing `default` and `unknown case` as described below under "Alternatives considered".

In the single value situation, `unknown case` must go last to avoid these issues. It's not possible to enforce the same thing for arbitrary patterns because there may be multiple enums in the pattern whose unknown cases need to be treated differently. This also means that it will be more difficult to suggest missing cases in compiler diagnostics, since the cases may be order-dependent.

A key point of this discussion is that as proposed `unknown case` merely produces a *warning* when the compiler can see that some enum cases are unhandled, rather than an error. This is what makes it difficult to implement in non-top-level positions. If the compiler produced an error instead, it would make more sense to use a pattern-like syntax for `unknown case` now (see the naming discussions under "Alternatives considered"). However, if the compiler produced an error, then adding a new case would not be a source-compatible change.

For all these reasons, generalized `unknown case` patterns are not being included in this proposal.


### Non-public cases

The work required for non-frozen enums also allows for the existence of non-public cases in a public enum. This already shows up in practice in Apple's SDKs, as described briefly in the section on "C enums" above. Like "enum inheritance", this kind of behavior can mostly be emulated by using a second enum inside the library, but that's not sufficient if the non-public values need to be vended opaquely to clients.

Were such a proposal to be written, I advise that a frozen enum not be permitted to have non-public cases.


### Compatibility checking

Of course, the compiler can't stop a library author from adding a new case to a non-frozen enum, even though that will break source and binary compatibility. We already have two ideas on how we could catch mistakes of this nature:

- A checker that can compare APIs across library versions, using swiftmodule files or similar.

- Encoding the layout of a type in a symbol name. Clients could link against this symbol so that they'd fail to launch if it changes, but even without that an automated system could check the list of exported symbols to make sure nothing was removed.

Frozen enums remain useful even without any automated checking, and such checking should account for more than just enums, so it's not being included in this proposal.


### Efficient representation of enums with raw types

For enums with raw types, a 32-bit integer can be used as the representation rather than a fully opaque value, on the grounds that 4 billion is a reasonable upper limit for the number of distinct cases in an enum without payloads. However, this would make it an ABI-breaking change to add or remove a raw type from an enum, and would make the following definitions not equivalent:

```swift
/* non-frozen */ public enum HTTPMethod: String {
  case get = "GET"
  case put = "PUT"
  case post = "POST"
  case delete = "DELETE"
}
```

```swift
/* non-frozen */ public enum HTTPMethod: RawRepresentable {
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


### Revision-locked imports

When a client module decides to import a *specific* version of a library, there's no danger of a non-frozen enum changing out from under them. This isn't something that can be done with system libraries, but it could be useful both for libraries you build yourself and for dependencies you plan to ship with your application. A few people have proposed syntax to indicate this:

```swift
static import ContrivedExampleKit
// or
import ContrivedExampleKit @ 1.20 // verifies the version number somehow
```

With this syntax, all public enums in the library will be treated as frozen. (It's questionable whether this also applies to libraries re-exported through the library named here as well.) This syntax would not, of course, be valid to use with libraries that are shipped as part of an OS; those libraries may be updated *without* recompiling the client, and so unknown cases must be handled.

I'm leery of this being used for packages that depend on other packages, which would keep a client of both libraries from being able to update them each independently. That said, it's useful when you have a *multi-module* package, where the two targets in the package will clearly never get out of sync. (It's also mildly useful for multi-module *applications,* but there you can just mark every public enum as `@frozen` and get the same effect.)

This is an additive feature that does not affect ABI, and as such could be added to the language in the future.


## Alternatives considered

### Syntax

#### Annotation naming: "closed" and "open"

The original description of the problem used "closed" and "open" to describe frozen and non-frozen enums, respectively. However, this conflicts with the use of `open` in classes and their members. In this usage, `open` is clearly a greater level of access than `public`, in that clients of an `open` class can do everything they can with a `public` class and more; it is source-compatible to turn a `public` class into an `open` one. For enums, however, it is frozen enums that are "greater": you can do everything you can with a non-frozen enum and more, and it is source-compatible to turn a non-frozen enum into a frozen one (at the cost of a warning).


#### Annotation naming: other options

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

I didn't have a strong preference for any particular choice as long as it *isn't* "closed" / "open", for the reasons described above. In the first revision of this proposal I picked `exhaustive` because it matches the name proposed [in Rust][rust]. (Unfortunately, Clang's `enum_extensibility` attribute, recently added by us at Apple, uses `open` and `closed`.)

Note that "nonextensible" does have one problem: Apple already uses [`NS_TYPED_EXTENSIBLE_ENUM `][NS_TYPED_EXTENSIBLE_ENUM] to refer to enum-like sets of constants (usually strings) that *clients* can add "cases" to. That's not the same meaning as the exhaustiveness discussed in this proposal.

During the first review for this proposal, Brent Royal-Gordon suggested `@frozen`, which was met with general approval or at least no major objections.

  [NS_TYPED_EXTENSIBLE_ENUM]: https://developer.apple.com/library/content/documentation/Swift/Conceptual/BuildingCocoaApps/InteractingWithCAPIs.html#//apple_ref/doc/uid/TP40014216-CH8-ID206


#### Modifier or attribute?

This proposal suggests a new *attribute* for enums, `@frozen`; it could also be a modifier `frozen`, implemented as a context-sensitive keyword. The original version of the proposal went with a modifier because most attributes only affect the *definition* of an API, not its use, but in preliminary discussions the core team felt that an attribute was a better fit.


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


#### `unknown case` naming

The first version of this proposal did not include `unknown case`, but did discuss it as a "considered alternative" under the name `future`. Previous discussions have also used `unexpected`, `undeclared`, or a plain `unknown` to describe this feature as well.

It was pointed out that neither `future` nor `unexpected` really described the feature being provided. `unknown case` does not just handle cases added in the future; it also handles private cases and invalid values for C enums. Nor are such cases entirely unexpected, since the compiler is telling the developer to expect them. `undeclared` has fewer issues, but certainly private cases are declared *somewhere;* the declarations just aren't visible.

It would be nice™ if we could just spell this new case `unknown`. However, that's ambiguous with the existing syntax for labeled control-flow statements:

```swift
switch excuse {
case .eatenByPet:
  // …
case .thoughtItWasDueNextWeek:
  complainLoudly()
  unknown: for next in contrivedExamples {
    for inner in moreContrivedExamples {
      if inner.use(next) {
        break unknown
      }
    }
  }
}
```

While it is *unlikely* that someone would use `unknown` for a control-flow label, it is possible. Making `unknown` a contextual keyword before `case` preserves this source compatibility.

During discussion, the name `unknown default` was suggested as an alternative to `unknown case`, since the semantics behave very much like `default`. I went with `unknown case` because it's a little shorter and a little more descriptive ("this is what to do with cases---as in enum cases---that I don't know about right now"), but I'm not too attached to it.

A bigger change would be to make a custom *pattern* instead of a custom *case,* even if it were subject to the same restrictions in implementation (see "`unknown case` patterns" above). This usually meant using a symbol of some kind to distinguish the "unknown" from a normal label or pattern, leading to `case #unknown` or similar. This makes the new feature less special, since it's "just another pattern". However, it would be surprising to have such a pattern but keep the restrictions described in this proposal; thus, it would only make sense to do this if we were going to implement fully general pattern-matching for this feature. See "`unknown case` patterns" above for more discussion.


### `switch!`

`switch!` was an alternative to `unknown case` that would not support any action other than trapping when the enum is not one of the known cases. This avoids some of the problems with `unknown case` (such as making it much less important to test), but isn't exactly in the spirit of non-frozen enums, where you *know* there will be more cases in the future.

The following two examples would be equivalent (except perhaps in the form of the diagnostic produced).

```swift
switch! excuse {
case .eatenByPet:
  // …
case .thoughtItWasDueNextWeek:
  // …
}
```

```swift
switch excuse {
case .eatenByPet:
  // …
case .thoughtItWasDueNextWeek:
  // …
unknown case:
  fatalError("unknown case in switch: \(excuse)")
}
```


### Testing invalid cases

Another issue with non-frozen enums is that clients cannot properly test what happens when a new case is introduced, almost by definition. Brent Royal-Gordon came up with the idea to have a new type annotation that would allow the creation of an invalid enum value. Since this is only something to use for testing, the initial version of the idea used `@testable` as the spelling for the annotation. The tests could then use a special expression, `#invalid`, to pass this invalid value to a function with a `@testable` enum parameter.

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


### Implicitly treat enums without binary compatibility concerns as `@frozen`

Several people questioned whether it was necessary to make this distinction for libraries without binary compatibility concerns, i.e. those that are shipped with their client apps. While there may be a need to do something to handle enums shipped with Apple's OS SDKs, it's arguable whether this is worth it for "source libraries", such as SwiftPM packages.

This question can be rephrased as "is adding a case to an enum a source-breaking change?" The distinction between frozen and non-frozen enums puts that choice in the hands of the library author, with the default answer—the one that does not require extra annotation—being "no, it is not". If adding a new enum case is not a source-breaking change, then it can be done in a minor version release of a library, one intended to be backwards-compatible. Like deprecations, this can produce new warnings, but not new errors, and it should not (if done carefully) break existing code. This isn't a critical feature for a language to have, but I would argue that it's a useful one for library developers.

> I wrote a [longer response] to this idea to Dave DeLong on the swift-evolution list. Dave [wasn't entirely convinced][delong-response].

  [longer response]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20180101/042530.html
  [delong-response]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20180101/042549.html


### Leave out `unknown case`

The [initial version][] of this proposal did not include `unknown case`, and required people to use `default` to handle cases added in the future instead. However, many people were unhappy with the loss of exhaustivity checking for `switch` statements, both for enums in libraries distributed as source and enums imported from Apple's SDKs. While this is an additive feature that does not affect ABI, it seems to be one that the community considers a necessary part of a language model that provides non-frozen enums.

  [initial version]: https://github.com/apple/swift-evolution/blob/a773d07ff4beab8b7855adf0ac56d1e13bb7b44c/proposals/0192-non-exhaustive-enums.md


### Mixing `unknown case` and `default`

The proposal as written forbids including both `unknown case` and `default` in the same `switch`. It's certainly possible to define what it would mean:

```swift
switch excuse {
case .eatenByPet:
  // Specific known case
unknown case:
  // Any cases not recognized by the compiler
default:
  // Any other cases the compiler *does* know about,
  // such as .thoughtItWasDueNextWeek
}
```

However, I can't think of an actual use case for this; it's not clear what action one would take in the `unknown case` that they wouldn't take in the `default` case. Furthermore, this becomes a situation where the same code behaves differently before and after recompilation:

1. A new case is added to the HomeworkExcuse enum, say, `droppedInMud`.
2. When using the new version of the library with an existing built client app, the `droppedInMud` case will end up in the `unknown case` part of the `switch`.
3. When the client app *is* recompiled, the `droppedInMud` case will end up in the `default` case. The compiler will not (and cannot) provide any indication that the behavior has changed.

Without a resolution to these concerns, this feature does not seem worth including in the proposal. It's also additive and has no ABI impact, so if we do find use cases for it in the future we can always add it then.


### Non-frozen enums in Swift 4 mode

This proposal provides no way to declare non-frozen enums in Swift 4 mode. We would need to introduce a new attribute (`@nonfrozen`) to allow that. Since we expect people to move projects to Swift 5 over time, however, this isn't a long-term concern. Not every new feature needs to be available in Swift 4 mode, and the proposal is simpler without a negative attribute.


### Introduce a new declaration kind instead

There have been a few suggestions to distinguish `enum` from some other kind of declaration that acts similarly but allows adding cases, which would avoid breaking compatibility with Swift 4:

```swift
choices HomeworkExcuse {
  case eatenByPet
  case thoughtItWasDueNextWeek
}
```

My biggest concern with this is that it increases the possibility of a library author accidentally publishing a (frozen) `enum` when they meant to publish a (non-frozen) `choices`. As described above, the opposite mistake is one that can be corrected without breaking source compatibility, but this one cannot.

A smaller concern is that both `enum` and `choices` would behave the same when they *aren't* `public`.

Stepping back, increasing the surface area of the language in this way does not seem desirable. Exhaustivity has been a key part of how Swift enums work, but it is not their only feature. Given how people already struggle with the decision of "struct vs. class" when defining a new type, introducing another pair of "similar but different" declaration kinds would have to come with strong benefits.

My conclusion is that it is better to think of frozen and non-frozen enums as two variants of the same declaration kind, rather than as two different declaration kinds.


### Use protocols instead

Everything you can do with non-frozen enums, you can do with protocols as well, except for:

- exhaustivity checking with `unknown case`
- forbidding others from adding their own "cases"

```swift
protocol HomeworkExcuse {}
struct EatenByPet: HomeworkExcuse {}
struct ThoughtItWasDueNextWeek: HomeworkExcuse {}

switch excuse {
case is EatenByPet:
  // …
case is ThoughtItWasDueNextWeek:
  // …
default:
  // …
}
```

(Associated values are a little harder to get out of the cases, but let's assume we could come up for syntax as well.)

This is a valid model; it's close to what Scala does (as mentioned above), and is independently useful in Swift. However, using this as the only way to get non-frozen enum semantics would lead to a world where `enum` is dangerous for library authors, because `public enum` is now a promise that no new cases will be added. Nothing else in Swift works that way. More practically, getting around this restriction would mean rewriting existing code to use the more verbose syntax of separate types conforming to a common protocol.

(If Swift were younger, perhaps we would consider using protocols for *all* non-imported enums, not just non-frozen ones. But at this point that would be *way* too big a change to the language.)


### Import non-frozen C enums as RawRepresentable structs

The Swift compiler already makes a distinction between plain C enums, enums marked with the `flag_enum` Clang attribute (`NS_OPTIONS`), and enums marked with the `enum_extensibility` Clang attribute (`NS_ENUM`). The first two categories were deemed to not be sufficiently similar to Swift enums and are imported instead as structs. Given that we're most immediately concerned about *C* enums growing new cases (specifically, those in Apple's existing Objective-C SDKs), we could sidestep the problem by importing *all* C enums as structs except for those marked `enum_extensibility(closed)`. However, this doesn't solve the problem for future Swift libraries, while still requiring changes to existing `switch` statements across many many projects. Furthermore, it would probably be harder to implement high-quality migration support from Swift 4 to Swift 5, since the structs-formerly-enums will look like any other structs imported from C.


### Get Apple to stop adding new cases to C enums

This isn't going to happen, but I thought I'd mention it since it was brought up during discussion. While some may consider this a distasteful use of the C language, it's an established pattern for Apple frameworks and is not going to change.


### "Can there be a kind of open enum where you can add new cases in extensions?"

There is no push to allow adding new cases to an enum from *outside* a library. This use case (no pun intended) is more appropriate for a RawRepresentable struct, where the library defines some initial values as static properties. (You can already switch over struct values in Swift as long as they are Equatable.)
