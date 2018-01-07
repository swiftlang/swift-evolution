# Derived Collection of Enum Cases

* Proposal: [SE-0194](0194-derived-collection-of-enum-cases.md)
* Authors: [Jacob Bandes-Storch](https://github.com/jtbandes), [Brent Royal-Gordon](https://github.com/brentdax), [Robert Widmann](https://github.com/CodaFi)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active review (January 6...11)**
* Implementation: [apple/swift#13655](https://github.com/apple/swift/pull/13655)

## Introduction

> *It is a truth universally acknowledged, that a programmer in possession of an `enum` with many cases, must eventually be in want of dynamic enumeration over them.*

[Enumeration types][enums] without associated values (henceforth referred to as "*simple enums*") have a finite, fixed number of cases, yet working with them programmatically is challenging. It would be natural to enumerate all the cases, count them, determine the highest `rawValue`, or produce a Collection of them. However, despite the fact that both the Swift compiler and the Swift runtime are aware of this information, there is no safe and sanctioned way for users to retrieve it. Users must resort to various [workarounds](#workarounds) in order to iterate over all cases of a simple enum.

This topic was brought up [three][se1] [different][se2] [times][se3] in just the first two months of swift-evolution's existence. It was the [very first language feature request][SR-30] on the Swift bug tracker. It's a [frequent][so1] [question][so2] on Stack Overflow (between them, these two questions have over 400 upvotes and 60 answers). It's a [popular][nateblog] [topic][ericablog] on blogs. It is one of just eight [examples][sourcery] shipped with Sourcery.

We propose the introduction of a protocol, `ValueEnumerable`, to indicate that a type has a finite, enumerable set of values. Moreover, we propose an opt-in derived implementation of `ValueEnumerable` for the common case of a simple enum.

### Prior discussion on Swift-Evolution
- [List of all Enum values (for simple enums)][se1] (December 8, 2015)
- [Proposal: Enum 'count' functionality][se2] (December 21, 2015)
- [Draft Proposal: count property for enum types][se3] (January 17, 2016)
- † [Pre-proposal: CaseEnumerable protocol (derived	collection of enum cases)][se4] (January 17, 2016)
- † [ValueEnumerable protocol with derived implementation for enums][se5] (April 15, 2016)

…more than a year passes…

- [[Pitch] Synthesized static enum property to iterate over cases][se6] (September 8, 2017)
- † [Re-pitch: Deriving collections of enum cases][se7] (November 6, 2017)

_**†** = a precursor to this proposal_

[se1]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001233.html
[se2]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151221/003819.html
[se3]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006853.html
[se4]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006876.html
[se5]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160411/015098.html
[se6]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170904/039598.html
[se7]: https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20171106/040950.html

[so1]: http://stackoverflow.com/questions/24007461/how-to-enumerate-an-enum-with-string-type
[so2]: http://stackoverflow.com/questions/27094878/how-do-i-get-the-count-of-a-swift-enum

[enums]: https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Enumerations.html
[SR-30]: https://bugs.swift.org/browse/SR-30
[nateblog]: http://natecook.com/blog/2014/10/loopy-random-enum-ideas/
[ericablog]: http://ericasadun.com/2015/07/12/swift-enumerations-or-how-to-annoy-tom/
[sourcery]: https://cdn.rawgit.com/krzysztofzablocki/Sourcery/master/docs/enum-cases.html


## Motivation

### Use cases

Examples online typically pose the question "How do I get all the enum cases?", or even "How do I get the count of enum cases?", without fully explaining what the code will do with that information. To guide our design, we focus on two categories of use cases:

1. The code must greedily iterate over all possible cases, carrying out some action for each case. For example, imagine enumerating all combinations of suit and rank to build a deck of playing cards:

    ```swift
    let deck = Suit.magicListOfAllCases.flatMap { suit in
        (1...13).map { rank in
            PlayingCard(suit: suit, rank: rank)
        }
    }
    ```

2. The code must access information about all possible cases on demand. For example, imagine displaying all the cases through a lazy rendering mechanism like `UITableViewDataSource`:

    ```swift
    class SuitTableViewDataSource: NSObject, UITableViewDataSource {
        func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
            return Suit.magicListOfAllCases.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            let suit = Suit.magicListOfAllCases[indexPath.row]
            cell.titleView!.text = suit.localizedName
            return cell
        }
    }
    ```

To limit our scope, we are primarily interested in *simple* enums—those without any associated values—although we would also like to allow more complicated enums and structs to manually participate in this mechanism.

The second use case suggests that access by contiguous, zero-based integer index is important for at least some uses. At minimum, it should be easy to construct an `Array` from the list of cases, but ideally the list could be used like an array directly, at least for simple enums.


### Workarounds

The most basic approach to producing a collection of all cases is by manual construction:

```swift
enum Attribute {
  case date, name, author
}
protocol Entity {
  func value(for attribute: Attribute) -> Value
}
// Cases must be listed explicitly:
[Attribute.date, .name, .author].map{ entity.value(for: $0) }.joined(separator: "\n")
```

For `RawRepresentable` enums, users have often relied on iterating over the known (or assumed) allowable raw values:

*Excerpt from Nate Cook's post, [Loopy, Random Ideas for Extending "enum"][nateblog] (October 2014):*

```swift
enum Reindeer: Int {
    case Dasher, Dancer, Prancer, Vixen, Comet, Cupid, Donner, Blitzen, Rudolph
}
extension Reindeer {
    static var allCases: [Reindeer] {
        var cur = 0
        return Array(
            GeneratorOf<Reindeer> {
                return Reindeer(rawValue: cur++)
            }
        )
    }
    static var caseCount: Int {
        var max: Int = 0
        while let _ = self(rawValue: ++max) {}
        return max
    }
    static func randomCase() -> Reindeer {
        // everybody do the Int/UInt32 shuffle!
        let randomValue = Int(arc4random_uniform(UInt32(caseCount)))
        return self(rawValue: randomValue)!
    }
}
```

Or creating the enums by `unsafeBitCast` from their hashValue, which is assumed to expose their memory representation:

*Excerpt from Erica Sadun's post, [Swift: Enumerations or how to annoy Tom][ericablog], with full implementation in [this gist](https://gist.github.com/erica/dd1f6616b4124c588cf7) (July 12, 2015):*

```swift
static func fromHash(hashValue index: Int) -> Self {
    let member = unsafeBitCast(UInt8(index), Self.self)
    return member
}

public init?(hashValue hash: Int) {
    if hash >= Self.countMembers() {return nil}
    self = Self.fromHash(hashValue: hash)
}
```

Or using a `switch` statement, making it a compilation error to forget to add a case, as with Dave Sweeris's [Enum Enhancer](https://github.com/TheOtherDave/EnumEnhancer) (which includes some extra functionality to avoid the boilerplate required for `.cases` and `.labels`):

```swift
enum RawValueEnum : Int, EnumeratesCasesAndLabels {
    static let enhancer:EnumEnhancer<RawValueEnum> = EnhancedGenerator {
        // `$0` is a RawValueEnum?
        switch $0 {
        case .none: $0 = .zero
        case .some(let theCase):
            switch theCase {
            case .zero: $0 = .one
            case .one: $0 = nil
            }
        }
    }
    case zero = 0
    case one = 1
}
```

There are many problems with these existing techniques:

- They are ad-hoc and can't benefit every enum type without duplicated code.
- They are not standardized across codebases, nor provided automatically by libraries such as Foundation and {App,UI}Kit.
- They are dangerous at worst, bug-prone in most cases (such as when enum cases are added, but the user forgets to update a hard-coded static collection), and awkward at best.

### Resilience implications

This last point is especially important as we begin to concern ourselves with library resilience. Future versions of Swift should allow library authors to add and deprecate public enum cases without breaking binary compatibility. But if clients are manually constructing arrays of "all cases", those arrays will not correspond to the version of the library they are running against.

At the same time, the principle that libraries ought to control the promises they make should apply to any case-listing feature. Participation in a "list all cases" mechanism should be optional and opt-in.

### Precedent in other languages

- Rust does not seem to have a solution for this problem.

- C#'s Enum has several [methods](https://msdn.microsoft.com/en-us/library/system.enum_methods.aspx) available for reflection, including `GetValues()` and `GetNames()`.

- Java [implicitly declares](http://docs.oracle.com/javase/specs/jls/se8/html/jls-8.html#jls-8.9.3) a static `values()` function, returning an array of enum values, and `valueOf(String name)` which takes a String and returns the enum value with the corresponding name (or throws an exception). More examples [here](http://docs.oracle.com/javase/specs/jls/se8/html/jls-8.html#jls-8.9.3).

- The Template Haskell extension to Haskell provides a function `reify` which extracts [info about types](http://hackage.haskell.org/package/template-haskell-2.10.0.0/docs/Language-Haskell-TH-Syntax.html#t:Info), including their constructors.

## Proposed solution

We propose introducing a `ValueEnumerable` protocol to the Swift Standard Library. The compiler will derive an implementation automatically for simple enums when the conformance is specified.

```swift
enum Ma: ValueEnumerable { case 马, 吗, 妈, 码, 骂, 麻, 🐎, 🐴 }

Ma.allValues         // returns some Collection whose Iterator.Element is Ma
Ma.allValues.count   // returns 8
Array(Ma.allValues)  // returns [Ma.马, .吗, .妈, .码, .骂, .麻, .🐎, .🐴]
```

## Detailed design

- The `ValueEnumerable` protocol will have the following declaration:

  ```swift
  public protocol ValueEnumerable {
    associatedtype ValueCollection: Collection where ValueCollection.Element == Self
    static var allValues: ValueCollection { get }
  }
  ```

- The compiler will synthesize an implementation of ValueEnumerable for an enum type if and only if:

  - the enum contains only cases without associated values;
  - the enum is not `@objc`;
  - the enum has an explicit `ValueEnumerable` conformance (and does not fulfil the protocol's requirements).

- Enums **imported from C/Obj-C headers** have no runtime metadata, and thus will not participate in the derived ValueEnumerable conformance, given the proposed implementation.

- Cases marked `unavailable` or `deprecated` **will be** included in `allValues`, because they are present in the metadata. (Note that `switch` statements are already required to handle these cases.)


## Naming

**tl;dr: Core team, please bikeshed!**

The names `ValueEnumerable` / `T.allValues` were chosen for the following reasons:

- the `-able` suffix indicates the [**capability**](https://swift.org/documentation/api-design-guidelines.html) to enumerate the type's values.
- the `all-` prefix avoids confusion with other meanings of the word "values" (plural noun; transitive verb in simple present tense).
- avoids the word "case", which might imply that the feature is `enum`-specific.
- avoids the word "finite", which is slightly obscure — and finiteness is not a necessary condition for iterating over values.

However, this proposal isn't all-or-nothing with regards to names; final naming should of course be at the Swift team's discretion. Other alternatives considered include:

- `T.values`
- `CaseEnumerable` / `T.cases` / `T.allCases`
- `FiniteType`
- `FiniteValueType`

## Source compatibility

This proposal only adds functionality, so existing code will not be affected. (The identifier `ValueEnumerable` doesn't make very many appearances in Google and GitHub searches.)


## Effect on ABI stability

The proposed implementation **adds** a runtime function `swift_EnumEnumerateCaseValues` returning the number of cases in a simple enum given its metadata. Changes to user code (adding or removing a case of a simple enum) do not affect ABI.

## Effect on API resilience

User programs will come to rely on the `ValueEnumerable` protocol and its `allValues` and `ValueCollection` requirements. Due to the use of an associated type for the property's type, the derived implementation is free to change the concrete Collection it returns without breaking the API.


## Implementation

In 2016, Robert Widmann put together a [sample implementation](https://github.com/apple/swift/commit/b8e6e9ff2e59c4834933dcd0fa7dd537fb25caaa) of CaseEnumerable. It provides a runtime function to read the number of cases from the enum type's metadata, and uses `Builtin.reinterpretCast` to convert each value to the enum type.


## Alternatives considered

The community has not raised any solutions whose APIs differ significantly from this proposal, except for solutions which provide strictly **more** functionality.

The functionality could also be provided entirely through the `Mirror`/reflection APIs. This would likely result in much more obscure and confusing usage patterns.

Unavailable and deprecated cases could be excluded from `allValues`. This would require modifications to metadata or an implementation that does not rely on metadata.

#### Provide a default collection 

Declaring this in the Standard Library reduces the amount of compiler magic required
to implement the protocol.  However, it also exposes a public unsafe entrypoint to the
reflection API that we consider unacceptable.

```swift
extension ValueEnumerable where ValueCollection == DefaultCaseCollection<Self> {
    public static var allValues: DefaultCaseCollection<Self> {
        return DefaultCaseCollection(unsafeForEnum: Self.self)
    }
}

public struct DefaultCaseCollection<Enum>: RandomAccessCollection {
    public var startIndex: Int { return 0 }
    public let endIndex: Int

    public init(unsafeForEnum _: Enum.Type) {
        endIndex = _countCaseValues(Enum.self)
    }

    public subscript(i: Int) -> Enum {
        precondition(indices.contains(i), "Case index out of range")
        return Builtin.reinterpretCast(i) as Enum
    }
}
```
