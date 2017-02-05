# Ease restrictions on protocol nesting

* Proposal: [SE-XXXX](xxxx-ease-protocol-nesting.md)
* Authors: [Karl Wagner](https://github.com/karlwa)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

Protocols define a way to express a syntactic and semantic contract. This semantic nature means that protocols are often intended to used in the context of one specific type (such as a 'delegate' protocol). Similarly, protocols sometimes wish to define specific types to be used within the context of that protocol (usually an `enum`).

This proposal would allow protocols to be nested in other types (including other protocols), and for structural types to be nested inside of protocols -- subject to a few constraints.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161017/028112.html)

## Motivation

Nesting types inside other types allows us to scope their usage and provide a cleaner interface. Protocols are an important part of Swift, and many popular patterns (for example, the delegate pattern) define protocols which are intended to be used in the semantic context of other types. It would be nice to apply type-nesting here: `MyClass.Delegate` reads better than `MyClassDelegate`, and literally brings structure to large frameworks.

Similarly, we have examples of protocols in the standard library which define supporting types to be used in the context of that protocol - `FloatingPointClassification`, `FloatingPointSign`, and `FloatingPointRoundingRule` are enums which are used by various members of the `FloatingPoint` protocol. These types are part of the contract which the protocol defines, and so it would be nice if they could be nested within the protocol to reflect that (i.e. `FloatingPoint.Classification`, `FloatingPoint.Sign`, `FloatingPoint.RoundingRule`).

## Proposed solution

The first part is to allow protocols to be nested inside of non-generic structural types (for example, in the delegate pattern):

```swift
class AView {                    // A regular-old class
    protocol Delegate: class {   // A nested protocol
        func somethingHappened()
    }
    weak var delegate: Delegate?
}

class MyDelegate: AView.Delegate {
    func somethingHappened() { /* ... */ }
}
```

The second part is to allow nominal types to be nested inside of protocols (for example, `FloatingPoint.Sign`).

```swift
protocol FloatingPoint {  
    // 'Sign' is required for conformance, therefore good candidate for nesting.
    enum Sign {
        case plus
        case minus
    }
    var sign: Sign { get }
}
```

Similarly, protocols may be nested inside other protocols:

```swift
protocol Scrollable: class {     // A regular-old protocol.
    var currentPosition: Position { get }
    
    protocol Delegate: class {   // A nested protocol.
        func scrollableDidScroll(_: Scrollable, from: Position)
    }    
    weak var delegate: Delegate?
}

class MyScrollable: Scrollable {
    var currentPosition = Position.zero
    
    weak var delegate: Delegate?
}

extension MyController: Scrollable.Delegate {
    func scrollableDidScroll(_ scrollable: Scrollable, from: Position) { 
        let displacement = scrollable.currentPosition.x - from.x
        // ...
    }
}
```

**Namespacing:**

It is important to draw a distinction between a protocol's nested types and its associated types. Associated types are placeholders (similar to generic type parameters), to be defined individually by each type which conforms to the protocol (e.g. every `Collection` will have a unique type of `Element`). Nested types are standard nominal types, and they don't neccessarily have anything to do with the conforming type (e.g. they may have been added in a protocol extension). We would like to avoid importing _irrelevant_ types in to the namespaces of conformers, but at the same time provide a convenient interface for any _relevant_ nested types (e.g. `FloatingPoint.Sign` is clearly relevant to `Float`, and it would be nice to call it `Float.Sign`).

To achieve this, the compiler will generate hidden typealiases for all nested types which are used by the protocol's requirements. The `FloatingPoint` protocol requires that its members have a property of type `FloatingPoint.Sign`, so it is clearly a relevant type for anybody who conforms to `FloatingPoint`, and should be made convenient. The exception is nested protocols, which are not implicitly imported even if used by a requirement. For example:

```swift
protocol FloatingPoint {
   enum Sign {
       case plus
       case minus
   }
   var sign: Sign { get }   // 'Sign' is used by a requirement. exported via typealiases.
}

struct Float: FloatingPoint {
    // [implicit] typealias Sign = FloatingPoint.Sign
    var sign: Sign { /* ... */ } // Sugared type: Float.Sign (via typealias)
}

let _: FloatingPoint.Sign = (4.0 as Float).sign as Double.Sign // all good B)
```

Looking at the Scollable example again, we want to ensure programmers write `Scrollable.Delegate` when writing their conformances, and explicitly reject `MyScrollable.Delegate`. For that reason, the compiler will not synthesise typealiases for nested protocols:

```swift
protocol Scrollable: class {
    protocol Delegate: class {
        func scrollableDidScroll(_: Scrollable, from: Position)
    }    
    weak var delegate: Delegate? // nested protocol 'Delegate' used by requirement, but _not_ imported!.
}

class MyScrollable: Scrollable {
    // _no_ implicit typealias!
    weak var delegate: Delegate? // Unqualified lookup. Type is: Optional<Scrollable.Delegate>
}

extension MyController: Scrollable.Delegate { // <- We don't want to allow 'MyScrollable.Delegate' here!
    func scrollableDidScroll(_ scrollable: Scrollable, from: Position) { 
        // ...
    }
}
```

Other nested types (i.e. those not used by requirements) are also not implicitly imported. Consider the following example of a struct which is added to `RandomAccessCollection` by an extension; it has nothing to do with any particular Collection (because it cannot capture -- see below), so it is irrelevant to any particular conforming type:

```swift
extension RandomAccessCollection {
    /// A view of a collection which provides concurrent implementations of map, filter, forEach, etc..
    struct Concurrent<T: RandomAccessCollection> { /* ... */ }
    
    var concurrent: Concurrent<Self> { return Concurrent(self) }  // is not a requirement. No implicit typealiases for Concurrent<T>.
}

let _ = [1, 2, 3].concurrent   // type is: RandomAccessCollection.Concurrent<Array<Int>>, _not_ Array<Int>.Concurrent
```

It would be possible to work around this with a typealias. We might consider synthesising these too once we have the ability to have default parameters for generic types:

```swift
extension RandomAccessCollection {
    // Default is bound to 'Self', which we implement by creating a typealias.
    struct Concurrent<T: RandomAccessCollection = Self> { /* ... */ }

    // [implicit] typealias Concurrent = Concurrent<Self>
}

let _: Array<Int>.Concurrent = [1, 2, 3].concurrent // sugared type: Array<Int>.Concurrent
                                                    // canonical type: RandomAccessCollection.Concurrent<Array<Int>>
```

**Access Control:**

Currently, members of a protocol declaration may not have access-control modifiers. That should apply for nested type declarations, too. The nested type itself, however, may contain members with limited visibility (including a lack of visible initialisers). The exception is that class types may include `open` or `final` modifiers.

```swift
public protocol MyProtocol {    
    final class Context {                   // 'MyProtocol.Context' may not have any access control modifiers. Visibility: public.
        fileprivate let _parent: MyProtocol // 'MyProtocol.Context._parent', however, may have limited access.
        // No public initialisers. That's allowed.
    }
}
```

Nested types may also be declared inside of protocol extensions. Consistent with current language rules, nested type declarations inside of protocol extensions _may_ have access control:

```swift
extension FloatingPoint {
    internal enum SignOrZero {  // 'FloatingPoint.SignOrZero' may have limited access.
        case plus
        case minus
        case zero
    }
    internal var signOrZero: SignOrZero {
        if self == 0.0 { 
            return .zero
        }
        else switch self.sign {
           case .plus:  return .plus
           case .minus: return .minus
        }
    }
}
```

**Constrained extensions:**

Nested types may also be defined inside of constrained protocol extensions, although they share a single namespace with unconstrained extensions:

```swift
// View as a series of UTF8 characters
extension Collection where Element == UInt8 {
    struct UnicodeCharacterView: Collection { let _wrapped: AnyCollection<UInt8> } // Type: Collection.UnicodeCharacterView
}

// View as a series of UTF16 characters
extension Collection where Element == UInt16 {
    struct UnicodeCharacterView: Collection { let _wrapped: AnyCollection<UInt16> } // ERROR: Redefinition of type 'Collection.UnicodeCharacterView'. Workaround is to make unique, e.g. 'Collection.UTF16View'.
}
```

**Generic types:**

Protocols may be nested inside of generic types, but they are not parameterised by any generic parameters. In the example below, there is only one nested protocol: `MyCollectionView.Delegate`, not `MyCollectionView<Book>.Delegate` or `MyCollectionView<Movie>.Delegate`:

```swift
class MyCollectionView<MediaItem> : UICollectionView {
    protocol Delegate: class {
        func itemDidChange(at: Index)
    }
    weak var delegate: Delegate?
}

class MyController: MyCollectionView.Delegate { // Note, use of unparameterised 'MyCollectionView' to refer to nested protocol.
    func itemDidChange(at: Index) { /* ... */ }
}

MyCollectionView<Book>.delegate = MyController()
MyCollectionView<Song>.delegate = MyController()
MyCollectionView<Movie>.delegate = MyController()
```


### Limitations

This proposal leaves one major limitation on protocol nesting: that nested types may not capture any types from (or through) a parent protocol. There is a 2x2 matrix of cases to consider here: when a nested protocol/nominal type captures a type parameter from a parent protocol/nominal types. The TLDR version is:

| Capture from parent (V)\ by nested (H) | Protocol | Nominal Type |
| ------------- | ------------- |---|
| Protocol  | No  | No |
| Nominal Type  | No | Yes! but not through a protocol. |

Essentially this is due to compiler limitations around existentials. If/when the compiler is capable of more comprehensive existentials, we can revisit capturing across nested generic protocols/types. There are enough useful cases which do not depend on this ability (including in the standard library) that it's worth implementing what we can today, though.


## Detailed Design

Given that nesting infers some context to the inner type, and that there is some friction between protocols with associated types ("generic protocols") and generic types, this section seeks to clarify when capturing is/is not allowed. Although it references compiler limitations surrounding existentials, any such changes are _not a part of this proposal_.

- Protocols may not capture associated types

    ```swift
    protocol Stream {
        associatedtype Content
        protocol Receiver {
            func receive(content: Content) // ERROR: Cannot capture associated type 'Content' from 'Stream'
        }
        var receiver: Receiver { get set }
    }
    ```
    
    Fundamentally, this is a compiler limitation. Ideally, we would like to represent the capture roughly so:
    
    ```swift
    protocol Stream {
        associatedtype Content
        protocol Receiver {
            // [implicit] associatedtype Content
            func receive(content: Content)
        }
        var receiver: Any<Receiver where .Content == Content> { get set } // Not possible today.
    }
    ```
    
    Should this limitation be lifted, we can revisit capturing of associated types. 
    

- Protocols may not capture generic type parameters:

    Even if we wanted to do this with an implicit associated type, as mentioned above we couldn't represent the constrained protocol existential in the parent. This is also why protocols are not parameterised when nested inside of generic types, as we would like any capturing one day to be expressed via existentials:

    ```swift
    class MyCollectionView<MediaItem> : UICollectionView {
        protocol Delegate: class {
            // [implicit] associatedtype MediaItem
            func itemDidChange(in: MyCollectionView<MediaItem>, at: Index)
        }
        weak var delegate: Any<Delegate where .MediaItem == MediaItem> // Not possible today.
    }

    class BookController: MyCollectionView.Delegate {
        typealias MediaItem = Book
        func itemDidChange(in: MyCollectionView<Book>, at: Index) { /* ... */ }
    }
    
    class GenericController<MediaItem>: MyCollectionView.Delegate {
        // associatedtype 'MediaItem' bound to generic parameter.
        func itemDidChange(in: MyCollectionView<MediaItem>, at: Index) { /* ... */ }
    }

    MyCollectionView<Book>().delegate = BookController()
    MyCollectionView<Book>().delegate = GenericController<Book>()
    MyCollectionView<Song>().delegate = GenericController()  // type is: GenericController<Song>
    MyCollectionView<Movie>().delegate = GenericController() // type is: GenericController<Movie>
    ```

- Nominal types *may* capture generic type parameters, but not through a protocol

    Nominal types can already have nested types which capture parameters from their parents, and this proposal does not change that. However if we consider the possible capture hierarchies when protocols are involved, one situation is noteworthy:

    ```swift
    struct Top<X> {
        protocol Middle {
            enum Bottom {
                case howdy(X) // ERROR: Cannot capture 'X' from Top<X>
            }
            
            var bottomInstance : Bottom { get } // Would require capturing 'X'
        }
    }
    ```

    It isn't possible to refer to `Bottom` (or any types nested below it) from `Middle`, due to the above limitation on protocols capturing generic type parameters. Therefore the nesting is meaningless and should not be allowed.
    
- Nominal types may not capture associated types

    Consider the `RandomAccessCollection.Concurrent` example from before, if it were allowed to directly capture associated types from its enclosing protocol (rather than using generics, defaults and typealiases or whatnot):

     ```swift
    // Note: Pretend there is something called 'Parent' which is a captured 'Self' of the parent protocol.
    protocol RandomAccessCollection {

        struct Concurrent: RandomAccessCollection {
            typealias Element = Parent.Element
            typealias Index   = Parent.Index
            init(with: Parent) { /* ... */ }
        }
        var concurrent: Concurrent { return Concurrent(self) }
    }
    ```

    By capturing associated types, the type `RandomAccessCollection.Concurrent` would also become existential (something like `RAC.Concurrent where Parent == Array<Int>`). We could theoretically map the capture of 'Parent' in to a generic parameter behind-the-scenes, but this kind of capturing would only work for would-be captures from the immediate parent before we start having the familiar problem of protocols capturing associated types. It would be better to tackle capturing between nested protocol types seperatetely at a later date.
    
    ```swift
    protocol Top {
        associatedtype AssocTop
        
        protocol Middle {
            associatedtype AssocMiddle
            
            enum Result {                 // [implicit] Result<Parent: Middle, Parent_Parent: Top>
                case one(AssocMiddle)     // [implicit] Parent.AssocMidle
                case two(AssocTop)        // [implicit] Parent_Parent.AssocTop
            }
            var result: Result { get }    // [implicit] Result<Self, ???> - would need to capture 'Self' from Parent
        }
    }
    ```

That's a long explanation of why it's best to just bar any kind of capturing between protocols and structural types for now. We can maybe address this limitation at a later date, as part of broader support for existentials and according to demand.

## Source compatibility

Standard library changes making use of this feature will be part of another proposal.

Outside of the standard library, it is likely that the Clang importer could make use of this feature, as the delegate pattern is very common in Apple's platform SDKs. Changes such as `UITableViewDelegate` -> `UITableView.Delegate` can be migrated with a deprecated typealias:

```swift
@deprecated("Use UITableView.Delegate instead")
typealias UITableViewDelegate = UITableView.Delegate
```

## Effect on ABI stability

This proposal is only about the language feature, but it is likely to result in standard library and platform SDK changes.

## Effect on API resilience

Since all capturing is disallowed, this type of nesting would only change the name (in source and symbolic) of the relevant types.

## Alternatives considered

- The alternative to nesting is to namespace your types manually with a prefix, similar to what the standard library, Apple SDK overlays, and existing Swift programs already do. However, nested types and cleaner namespaces are one of the underrated benefits that developers - espcially coming from Objective-C - have always been excited about. We like clean and elegant APIs. From time to time somebody pops up on the mailing list to ask why we don't have this feature yet, and the changes proposed here usually are met with broad support.

- Nesting a structural type (with function bodies) inside of a protocol declaration is expected to be a little controversial. An alternative would be to require nested types to be defined inside of protocol extensions. This proposal leaves that as an option (indeed, that is the only way to provide access control for nested types), but does not require it. We don't encourage protocol declarations containing large concrete type bodies because those details are usually irrelevant to those looking to conform to the protocol, but for trivial cases it may be acceptable; that judgement is left to the programmer.
