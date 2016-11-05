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

Allow protocols to be nested in other types, and for other types (including other protocols) to be nested inside protocols, subject to a few constraints.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161017/028112.html)

## Motivation

Nesting types inside other types allows us to scope their usage and provide a cleaner interface. Protocols are an important part of Swift, and many popular patterns (for example, the delegate pattern) define protocols which are intended to be used in the context of other types. It would be nice to apply type-nesting here: `MyClass.Delegate` reads better than `MyClassDelegate`, and literally brings structure to large frameworks.

Similarly, we have examples in the standard library where supporting types are defined with the intention that they be used in the context of some protocol - `FloatingPointClassification`, `FloatingPointSign`, and `FloatingPointRoundingRule` are enums which are used by various members of the `FloatingPoint` protocol. It would also be nice to apply type-nesting here, with the enums belonging to the protocol itself - e.g. `FloatingPoint.Sign`.

## Proposed solution

There are two important restrictions to this proposal:
- Nested protocols may not capture generic type parameters from their contexts
- Nested types (including protocols) may not capture associated types from their contexts

These restrictions are due to currently-limited support for existential types. There are many interesting ideas to overcome both, but after discussions on the mailing lists, we should be able to handle most of the common cases with these limitations and it keeps things reasonable to implement.

The first part is to allow protocols to be nested inside of structural types (for example, in the delegate pattern):

```swift
class AView : MYView {

    protocol Delegate : class {
        func somethingHappened()
    }
    weak var delegate : Delegate?
    
    func doSomething() {
        //...
        delegate?.somethingHappened()
    }
}

class AController : MYViewController, AView.Delegate {
    
    func somethingHappened() {
        // Respond to callback
    }
}
```

Similarly, we will allow structural types to be nested inside of protocols (such as the standard library's `FloatingPoint*` enums):


```swift
protocol FloatingPoint {
    
    enum Sign {
        case plus
        case minus
    }
    
    var sign: Sign { get }
}

struct Float : FloatingPoint {

    var sign: FloatingPoint.Sign { /* return the sign */ }
}
```

And the same for protocols inside of protocols:

```swift
protocol TextStream {
    protocol Transformer {
        func transform(_: Character) -> Character
    }
    
    var transformers : [Transformer] { get set }
    func getNextCharacter() -> Character
}

struct WeLoveUmlauts : TextStream.Transformer {
    func transform(_ char: Character) -> Character {
        switch char {
            case "a".characters.first!: return "ä"
            case "e".characters.first!: return "ë"
            //...etc
            default: return char
        }
    }
}
```

In all of the examples, any of the structual types may have generic types, and any of the protocols may have associated types. So long as the restrictions mentioned earlier are observed, i.e. that no types are captured between a protocol and its outer or inner types.

## Source compatibility

This change is additive, although there are a couple of places in the standard library where we might consider reorganising things after this change. Those changes are not a part of this proposal.

## Effect on ABI stability

Would change the standard library ABI if it chose to adopt the feature.

## Effect on API resilience

Nesting changes the name (both in source and symbolic) of the relevant types. Has the same effect as other type renamings/nesting and un-nesting.

## Alternatives considered

The alternative is to namespace your types manually with a prefix, similar to what the standard library, Apple SDK overlays, and existing Swift programs already do. However, nested types and cleaner namespaces are one of the little things that developers - espcially coming from Objective-C - have always been really excited about. From time to time somebody pops up on the mailing list to ask why we don't have it yet for protocols, and changes proposed here usually are met with broad support.
