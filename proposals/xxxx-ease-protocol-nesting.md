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

The first part is to allow protocols to be nested inside of nominal types (for example, in the delegate pattern):

```swift
class AView {                    // A regular-old class
    protocol Delegate: class {   // A nested protocol
        func somethingHappened()
    }
    weak var delegate: Delegate? // Unqualified lookup: AView.Delegate
}

class MyDelegate: AView.Delegate {  // Qualified lookup: AView.Delegate
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
protocol Scrollable: class {     // A regular-old protocol
    var currentPosition: Position { get }
    
    protocol Delegate: class {   // A nested protocol
        func scrollableDidScroll(_: Scrollable, from: Position)
    }    
    weak var delegate: Delegate? // Unqualified lookup: Scrollable.Delegate
}

class MyScrollable: Scrollable {
    var currentPosition = Position.zero
    
    // implicit typealias Delegate = Scrollable.Delegate (see 'Namespacing')
    weak var delegate: Delegate? // type: Scrollable.Delegate
}

extension MyController: Scrollable.Delegate { // Qualified lookup: Scrollable.Delegate
    func scrollableDidScroll(_ scrollable: Scrollable, from: Position) { 
        let displacement = scrollable.currentPosition.x - from.x
        // ...
    }
}
```

**Namespacing:**

It is important to draw a distinction between a protocol's nested types and its associated types. Associated types are placeholders (similar to generic type parameters), to be defined individually by each type which conforms to the protocol (e.g. every `Collection` will have a unique type of `Element`). Nested types are standard nominal types which must be used by _every_ type which conforms to the protocol. Taking `FloatingPoint.Sign` as an example, conformance to the `FloatingPoint` protocol means that every conforming type has a property called `sign` whose value may one of a few enum cases defined _as part of the protocol_.

That being said, conformers will import the nested types of protocols in to their own namespaces via implicit typealiases to allow for unqualified lookup. This is nothing more than a convenient shorthand - `Float.Sign` is identical to `Double.Sign`, and generic code may refer to both with `FloatingPoint.Sign`. In the event of a naming collision, the latter spelling may be used to disambiguate.

```swift
// See: FloatingPoint.Sign example above

struct Float: FloatingPoint {
    // implicit: typealias Sign = FloatingPoint.Sign
    var sign: Sign { /* ... */ }
}

// Allowed. Double.Sign == Float.Sign == FloatingPoint.Sign
let _: Double.Sign = (3.0 as Float).sign
```

**Access Control:**

Currently, members of a protocol declaration may not have access-control modifiers. That should apply for nested type declarations, too. The nested type itself, however, may contain members with limited visibility (including a lack of visible initialisers). The exception is that class types may include `open` or `final` modifiers.

```swift
public protocol MyProtocol {    
    final class Context {                   // 'MyProtocol.Context' may not have any access control modifiers. Visibility: public.
        fileprivate let _parent: MyProtocol // 'MyProtocol.Context._parent', however, may have limited access.
        // No public initialisers. Allowed.
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

Nested types may also be defined inside of constrained protocol extensions, although they share a namespace with unconstrained extensions:

```swift
// View as a series of UTF8 characters
extension Collection where Element == UInt8 {
    // Type is Collection.UnicodeCharacterView
    struct UnicodeCharacterView: Collection { let _wrapped: AnyCollection<UInt8> }
}

// View as a series of UTF16 characters
extension Collection where Element == UInt16 {
    // ERROR: Redefinition of type 'Collection.UnicodeCharacterView'. Workaround would be to rename to 'Collection.UTF16View'.
    struct UnicodeCharacterView: Collection { let _wrapped: AnyCollection<UInt16> }
}
```


### Limitations

This proposal leaves one major limitation on protocol nesting: that nested types may not capture any types from (or through) a parent protocol. There is a 2x2 matrix of cases to consider here: when a nested protocol/structural type captures a type parameter from a parent protocol/structural types. The TLDR version is:

| Capture from parent (V)\ by nested (H) | Protocol | Structural Type |
| ------------- | ------------- |---|
| Protocol  | No  | No |
| Structural Type  | No | Yes! but not through a protocol. |

Essentially this is due to compiler limitations around existentials. If/when the compiler is capable of more comprehensive existentials, we can revisit capturing across nested generic protocols/types. There are enough useful cases which do not depend on this ability (including in the standard library) that it's worth implementing what we can today, though.


## Detailed Design

Given that there is some friction between protocols with associated types ("generic protocols") and generic structural types, and that nesting infers some context to the inner type, this section seeks to clarify when capturing is/is not allowed. Although it references compiler limitations surrounding existentials, any such changes are _not a part of this proposal_.

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
            // implicit: associatedtype Content
            func receive(content: Content)
        }
        var receiver: Any<Receiver where .Content == Content> { get set } // Not possible today.
    }
    ```
    
    Should this limitation be lifted, we can revisit capturing of associated types. 
    

- Protocols may not capture generic type parameters:

    Firstly, even if we wanted to do this via some sort of implicit associated type, as mentioned above we couldn't represent the existential in the parent. Secondly, there is a concern about parameterised protocols.

    ```swift
    struct MyType<X> {
       protocol MyProto {
           var content: X { get set } // ERROR: Cannot capture 'X' from MyType
       }       
       var protoInstance: MyProto
    }
    ```

- Structural types *may* capture generic type parameters, but not through a protocol

    Structural types can already have nested structural types which capture parameters from their parents, and this proposal does not change that. However if we consider the possible capture hierarchies when protocols are involved, one situation is notable:

    ```swift
    struct Top<X> {
        protocol Middle {
            enum Bottom {
                case howdy(X) // ERROR: Cannot capture 'X' from Top
            }
            
            var bottomInstance : Bottom { get } // If it _was_ allowed, this reference would also capture 'X'
        }
    }
    ```

    It isn't possible to refer to `Bottom` (or any types nested below it) from `Middle`, due to the above limitation on protocols capturing generic type parameters. Therefore the nesting is meaningless and should not be allowed.
    
- Structual types may not capture associated types

    Consider a hypothetical nested struct that captures an associated type from its parent protocol.

     ```swift
    // Note: Pretend there is something called 'Parent' which is a captured 'Self' of the parent protocol.
    protocol RandomAccessCollection {

        struct DefaultSlice: RandomAccessCollection {
            typealias Element = Parent.Element                     // ERROR: Cannot capture 'Element' from Parent
            init(from: Index, to: Index, in: Parent) { /* ... */ } // ERROR: Cannot capture 'Self' from Parent
        }
        
        associatedtype Slice: RandomAccessCollection = DefaultSlice
    }
    ```

    By capturing an associated type, the type `RandomAccessCollection.DefaultSlice` would also become existential (something like `RandomAccessCollection.DefaultSlice where Parent == Array`). We could theoretically map the capture of 'Parent' in to a generic parameter (although it is _not a part of this proposal_):

     ```swift
    protocol RandomAccessCollection {

        struct DefaultSlice: RandomAccessCollection { // implicit: DefaultSlice<Parent: RandomAccessCollection>
            typealias Element = Parent.Element
            init(from: Index, to: Index, in: Parent) { /* ... */ }
        }
        
        associatedtype Slice: RandomAccessCollection = DefaultSlice // implicit: DefaulSlice<Self>
    }

    let slice = RandomAccessCollection.DefaultSlice<Array>(from: 0, to: 1, in: [1, 2, 3, 4, 5])
    ```
    
    This would only work for would-be captures from the immediate parent, before we start having protocols capturing associated types:
    
    ```swift
    protocol Top {
        associatedtype AssocTop
        
        protocol Middle {
            associatedtype AssocMiddle
            
            enum Result { // implicit: <Parent_Parent: Top, Parent: Middle>
                case one(Parent_Parent.AssocTop)
                case two(Parent.AssocMiddle)
            }
            var result: Result { get } // implicit: <???, Self> - would need to capture 'Self' from Parent
        }
    }
    ```

So that's a long explanation of why it's best to just bar any kind of capturing between protocols and structural types for now. We can maybe address this limitation at a later date, as part of broader support for existentials and according to demand.

## Source compatibility

This change is mostly additive, although there are a couple of places in the standard library where we can organise things better after this change. Specifically:

- The `FloatingPoint{Sign,Classification,RoundingMode}` enums will become members of the `FloatingPoint` protocol
- The `MirrorPath` protocol will become a member of the `Mirror` struct, and renamed `Path`

Source migration can be handled with a typealias and deprecation notice (with fixit), for example:

```swift
@deprecated("Use FloatingPoint.Sign instead")
typealias FloatingPointSign = FloatingPoint.Sign
```

It is also likely that the Clang importer could make use of this feature, as the delegate pattern is very common in Apple's platform SDKs. Changes such as `UITableViewDelegate` -> `UITableView.Delegate` can be handled as above, with a deprecated typealias.

## Effect on ABI stability

Would change the standard library interface, platform SDK interfaces.

## Effect on API resilience

Since all capturing is disallowed, this type of nesting would only change the name (both in source and symbolic) of the relevant types.

## Alternatives considered

- The alternative to nesting is to namespace your types manually with a prefix, similar to what the standard library, Apple SDK overlays, and existing Swift programs already do. However, nested types and cleaner namespaces are one of the underrated benefits that developers - espcially coming from Objective-C - have always been excited about. We like clean and elegant APIs. From time to time somebody pops up on the mailing list to ask why we don't have this feature yet, and the changes proposed here usually are met with broad support.

- Nesting a structural type (with function bodies) inside of a protocol declaration is expected to be a little controversial. An alternative would be to require nested types to be defined inside of protocol extensions. This proposal leaves that as an option (indeed, that is the only way to provide access control for nested types), but does not require it. We don't encourage protocol declarations containing large concrete type bodies because those details are usually irrelevant to those looking to conform to the protocol, but for trivial cases it may be acceptable; that judgement is left to the programmer.
