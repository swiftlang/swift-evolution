# Derived Collection of Enum Cases

* Proposal: [SE-0194](0194-derived-collection-of-enum-cases.md)
* Authors: [Jacob Bandes-Storch](https://github.com/jtbandes), [Brent Royal-Gordon](https://github.com/brentdax), [Robert Widmann](https://github.com/CodaFi)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Review Thread: [SE-0194 review][se8]
* Status: **Implemented (Swift 4.2)**

## Introduction

> *It is a truth universally acknowledged, that a programmer in possession of an `enum` with many cases, must eventually be in want of dynamic enumeration over them.*

[Enumeration types][enums] without associated values (henceforth referred to as "*simple enums*") have a finite, fixed number of cases, yet working with them programmatically is challenging. It would be natural to enumerate all the cases, count them, determine the highest `rawValue`, or produce a Collection of them. However, despite the fact that both the Swift compiler and the Swift runtime are aware of this information, there is no safe and sanctioned way for users to retrieve it. Users must resort to various [workarounds](#workarounds) in order to iterate over all cases of a simple enum.

This topic was brought up [three][se1] [different][se2] [times][se3] in just the first two months of swift-evolution's existence. It was the [very first language feature request][SR-30] on the Swift bug tracker. It's a [frequent][so1] [question][so2] on Stack Overflow (between them, these two questions have over 400 upvotes and 60 answers). It's a [popular][nateblog] [topic][ericablog] on blogs. It is one of just eight [examples][sourcery] shipped with Sourcery.

We propose the introduction of a protocol, `CaseIterable`, to indicate that a type has a finite, enumerable set of values. Moreover, we propose an opt-in derived implementation of `CaseIterable` for the common case of a simple enum.

### Prior discussion on Swift-Evolution
- [List of all Enum values (for simple enums)][se1] (December 8, 2015)
- [Proposal: Enum 'count' functionality][se2] (December 21, 2015)
- [Draft Proposal: count property for enum types][se3] (January 17, 2016)
- † [Pre-proposal: CaseEnumerable protocol (derived	collection of enum cases)][se4] (January 17, 2016)
- † [ValueEnumerable protocol with derived implementation for enums][se5] (April 15, 2016)

…more than a year passes…

- [[Pitch] Synthesized static enum property to iterate over cases][se6] (September 8, 2017)
- † [Re-pitch: Deriving collections of enum cases][se7] (November 6, 2017)
- **Official Review**: [SE-0194: Derived Collection of Enum Cases][se8] (January 6, 2018)

_**†** = a precursor to this proposal_

[se1]: https://forums.swift.org/t/list-of-all-enum-values-for-simple-enums/337
[se2]: https://forums.swift.org/t/proposal-enum-count-functionality/711
[se3]: https://forums.swift.org/t/draft-proposal-count-property-for-enum-types/1103
[se4]: https://forums.swift.org/t/pre-proposal-caseenumerable-protocol-derived-collection-of-enum-cases/1109
[se5]: https://forums.swift.org/t/valueenumerable-protocol-with-derived-implementation-for-enums/2226
[se6]: https://forums.swift.org/t/pitch-synthesized-static-enum-property-to-iterate-over-cases/6623
[se7]: https://forums.swift.org/t/re-pitch-deriving-collections-of-enum-cases/6956
[se8]: https://forums.swift.org/t/review-se-0194-derived-collection-of-enum-cases/7377

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

We propose introducing a `CaseIterable` protocol to the Swift Standard Library. The compiler will derive an implementation automatically for simple enums when the conformance is specified.

```swift
enum Ma: CaseIterable { case 马, 吗, 妈, 码, 骂, 麻, 🐎, 🐴 }

Ma.allCases         // returns some Collection whose Iterator.Element is Ma
Ma.allCases.count   // returns 8
Array(Ma.allCases)  // returns [Ma.马, .吗, .妈, .码, .骂, .麻, .🐎, .🐴]
```

## Detailed design

- The `CaseIterable` protocol will have the following declaration:

  ```swift
  public protocol CaseIterable {
    associatedtype AllCases: Collection where AllCases.Element == Self
    static var allCases: AllCases { get }
  }
  ```

- The compiler will synthesize an implementation of CaseIterable for an enum type if and only if:

  - the enum contains only cases without associated values;
  - the enum declaration has an explicit `CaseIterable` conformance (and does not fulfill the protocol's requirements).

- Enums imported from C/Obj-C headers will **not** participate in the derived CaseIterable conformance.

- Cases marked `unavailable` will **not** be included in `allCases`.

- The implementation will **not** be synthesized if the conformance is on an `extension` — it must be on the original `enum` declaration.


## Source compatibility

This proposal only adds functionality, so existing code will not be affected. (The identifier `CaseIterable` doesn't make very many appearances in Google and GitHub searches.)


## Effect on ABI stability

The proposed implementation adds a derived conformance that makes use of no special ABI or runtime features.

## Effect on API resilience

User programs will come to rely on the `CaseIterable` protocol and its `allCases` and `AllCases` requirements. Due to the use of an associated type for the property's type, the derived implementation is free to change the concrete Collection it returns without breaking the API.


## Alternatives considered

The functionality could also be provided entirely through the `Mirror`/reflection APIs. This would likely result in much more obscure and confusing usage patterns.

#### Provide a default collection 

Declaring this in the Standard Library reduces the amount of compiler magic required
to implement the protocol.  However, it also exposes a public unsafe entrypoint to the
reflection API that we consider unacceptable.

```swift
extension CaseIterable where AllCases == DefaultCaseCollection<Self> {
    public static var allCases: DefaultCaseCollection<Self> {
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

### [Metatype conformance to Collection](https://forums.swift.org/t/re-pitch-deriving-collections-of-enum-cases/6956/11)

A *type* inherently represents a set of its possible values, and as such, `for val in MyEnum.self { }` could be a natural way to express iteration over all cases of a type. Specifically, if the metatype `MyEnum.Type` could conform to `Collection` or `Sequence` (with `Element == MyEnum`), this would allow `for`-loop enumeration, `Array(MyEnum.self)`, and other use cases. In a generic context, the constraint `T: CaseIterable` could be expressed instead as `T.Type: Collection`.

Absent the ability for a metatype to actually conform to a protocol, the compiler could be taught to treat the special case of enum types *as if* they conformed to Collection, enabling this syntax before metatype conformance became a fully functional feature.
