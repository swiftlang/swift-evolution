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

Nesting types inside other types allows us to scope their usage and provide a cleaner interface. Protocols are an important part of Swift, and many popular patterns (for example, the delegate pattern) define protocols which are intended to be used in the context of other types. It would be nice to apply type-nesting here: `MyClass.Delegate` reads better than `MyClassDelegate`, and literally brings structure to large frameworks.

Similarly, we have examples in the standard library where supporting types are defined with the intention that they be used in the context of some protocol - `FloatingPointClassification`, `FloatingPointSign`, and `FloatingPointRoundingRule` are enums which are used by various members of the `FloatingPoint` protocol. It would also be nice to apply type-nesting here, with the types belonging to the protocol itself - e.g. `FloatingPoint.Sign`.

## Proposed solution

The first part is to allow protocols to be nested inside of structural types (for example, in the delegate pattern):

```swift
class AView {
    protocol Delegate: class {
        func somethingHappened()
    }
    weak var delegate: Delegate?
}

class MyDelegate: AView.Delegate {
    func somethingHappened() { /* ... */ }
}
```

Similarly, we will allow structural types to be nested inside of protocols (such as the standard library's `FloatingPoint*` enums). These structural types are _part of the protocol_, not part of the conformers; they are an intrinsic part of the contract which the protocol expresses. As such, types defined inside the protocol body may not have access modifiers. If you wish to nest a type inside a protocol which is not _required_ for conformance, it is recommended that you define it in an  extension rather than the protocol body.

For convenience, types will import the nested types of protocols they conform to via implicit typealiases for unqualified lookup:

```swift
protocol FloatingPoint {  
    // 'Sign' is required for conformance, therefore good candidate for nesting.
    enum Sign {
        case plus
        case minus
    }
    var sign: Sign { get }
}

struct Float: FloatingPoint {
    // implicit: typealias Sign = FloatingPoint.Sign
    var sign: Sign { /* ... */ }
}

// Ok. Double.Sign == Float.Sign == FloatingPoint.Sign
let _: Double.Sign = (3.0 as Float).sign
```

Types may also be defined inside protocol extensions. As mentioned above, this is the recommended thing to do if your type requres access-control or, for any other reason, is not required to implement conformance to the protocol:

```swift
extension FloatingPoint {
    internal enum SignOrZero {
        case plus
        case minus
        case zero
    }
    internal var signOrZero: SignOrZero {
        // get ready for the 4-hour discussion IEEE754 and 0...
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

Similarly, protocols may be nested inside of other protocols:

```swift
protocol Scrollable {
    protocol Delegate: class {
        func scrollableDidScroll(_: Scrollable, from: Position)
    }    
    weak var delegate: Delegate?
    var currentPosition: Position { get }
}

extension MyController: Scrollable.Delegate {
    func scrollableDidScroll(_ scrollable: Scrollable, from: Position) { 
        let displacement = scrollable.currentPosition.x - from.x
        // ...
    }
}

class MyScrollable: Scrollable {
    var currentPosition = Position.zero
    // implicit typealias Delegate = Scrollable.Delegate
    weak var delegate: Delegate?
}
```

### Generics

This proposal leaves one major limitation on protocol nesting: that nested types may not capture any types from (or through) a parent protocol. There is a 2x2 matrix of cases to consider here: when a nested protocol/structural type captures a type parameter from a parent protocol/structural types. The TLDR version is:

| Capture from parent (V)\ by nested (H) | Protocol | Structural Type |
| ------------- | ------------- |---|
| Protocol  | No  | No |
| Structural Type  | No | Up to next protocol |


## Detailed Design

Elaborating on the generics interaction:

- Protocols may not capture generic type parameters:

    We could devise a way to implement this using implicit associated types, with any references to the nested type in the parent gaining implicit same-type constraints binding the two together. However, it is not possible to model such constraints in the compiler at this time. This is the fundamental limitation preventing capturing with protocols.
 
    _Also, we would check for protocols being nested inside empty generic types and warn that parameterized protocols are not cool_

    ```swift
    struct MyType<X> {
       protocol MyProto {
           // implicit: associatedtype X
           var content: X { get set }
       }
       
       var protoInstance: MyProto // should be: Any<MyProto where MyProto.X == Self.X> or equivalent
    }

    extension Something: MyType<String>.MyProto {
       // inferred: typealias X = String
       var content: String
    }
    ```

- Protocols may not capture associated types

    As mentioned above, capturing associated types requires that references to the nested type in the parent be constrained in a way that cannot currently be expressed in the language, and should be the subject of another proposal.

- Structural types *may* capture generic type parameters, but only up to the next protocol

    Structural types can already have nested structural types which capture parameters from their parents, and this proposal does not change that. However if we consider the possible capture hierarchies when protocols are involved, one situation is notable:

    ```swift
    struct Top<X> {
        protocol Middle {
            enum Bottom {
                case howdy(X) // Captures 'X' from Top
            }
            var bottomInstance : Bottom { get } // Uh-oh! Also captures 'X'
        }
    }
    ```

    We return to the limitation that the protocol `Middle` may not capture the generic parameter `X` (see above); therefore it would not be possible to make use of `Bottom` from `Middle`, and the nesting is meaningless.

    Lacking existential support, the above model can be translated in to a generic work-around:

     ```swift
    struct Top<X, MiddleType> where MiddleType: Middle, MiddleType.TypeOfX == X {
        protocol Middle {
            associatedtype TypeOfX
            enum Bottom {
                case howdy(TypeOfX) // Pretend it's okay to capture associated types. See generic workaround for _that_ below.
            }
            var bottomInstance : Bottom { get } // Does not capture X.
        }

        var middleInstance: MiddleType
    }
    ```

- Structual types may not capture associated types

    Consider the case of a nested type which captures two associated types from its parent protocol. Presumably this type is important to the protocol, so let's say it is exposed via a read-only property.

     ```swift
    protocol ProductionLine: class {
        associatedtype RawMaterial
        associatedtype Product

        open class Stage {
            func process(_: RawMaterial) {}
            var product: Product?
        }
        var currentStage: Stage { get } // where Product == Self.Product, RawMaterial == Self.RawMaterial
    }
    ```

    Capturing an associated type means the type `ProductionLine.Stage` also becomes existential. Again, compiler support for existentials is not comprehensive enough to express the neccessary constraints.
    
    One tempting workaround is to convert to generics (even as an implementation detail, hidden from the user-visible signature):

     ```swift
    protocol ProductionLine: class {
        associatedtype RawMaterial
        associatedtype Product

        open class Stage<L: ProductionLine> {
            func process(_: L.RawMaterial) {}
            var product: L.Product?
        }
        var currentStage: Stage<Self> // No captures.
    }
    ```
    
    but this only works for would-be captures from the immediate parent protocol, before we hit a familiar hurdle:
    ```swift
    protocol Manufacturer {
        associatedtype Product
        
        protocol ProductionLine {
            associatedtype RawMaterial
            
            open class Stage<Product, L: ProductionLine> {
                func process(_: L.RawMaterial) {} // Captured from ProductionLine
                var product: Product?             // Captured from Manufacturer
            }
            var currentStage: Stage<Product, Self> // Uh-oh! Captures associated type 'Product' from 'Manufacturer'!
        }
    }
    ```

So that's a long explanation of why it's best to just bar any kind of capturing between protocols and structural types for now. We can address this limitation at a later date, as part of broader support for existentials. 

## Source compatibility

This change is additive, although there are a couple of places in the standard library where we can organise things better after this change. Specifically:

- The `FloatingPoint{Sign,Classification,RoundingMode}` enums will become members of the `FloatingPoint` protocol
- The `MirrorPath` protocol will become a member of the `Mirror` struct, and renamed `Path`

Source migration can be handled with a typealias and deprecation notice, for example:

```swift
@deprecated("Use FloatingPoint.Sign instead")
typealias FloatingPointSign = FloatingPoint.Sign
```

## Effect on ABI stability

Would change the standard library interface.

## Effect on API resilience

Nesting changes the name (both in source and symbolic) of the relevant types. Has the same effect as other type renamings/nesting and un-nesting.

## Alternatives considered

- The alternative to nesting is to namespace your types manually with a prefix, similar to what the standard library, Apple SDK overlays, and existing Swift programs already do. However, nested types and cleaner namespaces are one of the little things that developers - espcially coming from Objective-C - have always been really excited about. From time to time somebody pops up on the mailing list to ask why we don't have it yet for protocols, and changes proposed here usually are met with broad support.

- Nesting a structural type inside of a protocol body seems controversial at first glance, for sure. The conceptual model for this is that the types are _part_ of the protocol contract. That is to say that anything which wants to conform to `FloatingPoint` must use the `Sign` enum that comes bundled inside of it.

 One alternative would be to require nested types to be defined inside of protocol extensions. However, currently protocol extensions do not consist of anything which is required to implement the protocol - they only consist of optional, overridable functionality. I believe it is better that the protocol body contains *all* of the requirements, even at the cost of being a little untidy, rather than to distribute the required interfaces across several extensions.

 Of course, there is nothing stopping anybody defining nested types in unconstrained protocol extensions and using them in the protocol body, similar to what is possible with typealiases today:

 Both acceptable:

 ```swift
protocol MyProto {
        var value: ValueType { get }
        typealias ValueType = Int
}
```
 and:

 ```swift
protocol MyProto {
        var value: ValueType { get }
}
// ...
extension MyProto {
        typealias ValueType = Int
}
```
