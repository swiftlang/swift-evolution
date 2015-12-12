# Replace `typealias` keyword with `associated` for associated type declarations

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-replace-typealias-associated.md)
* Author(s): [Loïc Lecrenier](https://github.com/loiclec)
* Status: **Review**
* Review manager: TBD

## Introduction

The `typealias` keyword is currently used to declare two kinds of types:

1. Type Aliases (alternative name for an existing type)
2. Associated Types (placeholder name to type used as part of a protocol)

These two kinds of declarations are different and should use distinct keywords.
This would emphasize the difference between them and reduce some of the
confusion surrounding the use of associated types.

The proposed new keyword is `associated`.

## Motivation

Re-using `typealias` for associated type declarations is confusing in many ways.

1. It is not obvious that `typealias` in protocols means something else than in
 other places.
2. It hides the existence of associated types to beginners, which allows them
 to write code they misunderstand.
3. It hides the absence of concrete type aliases inside protocols.

In particular, **2 + 3** leads to programmers writing

```swift
protocol Prot {
    typealias Container : SequenceType
    typealias Element = Container.Generator.Element
}
```

without realizing that `Element` is a new associated type with a default value
of `Container.Generator.Element` instead of a type alias to
`Container.Generator.Element`.

However, this code

```swift
protocol Prot {
    typealias Container : SequenceType
}
extension Prot {
    typealias Element = Container.Generator.Element
}
```

declares `Element` as a type alias to `Container.Generator.Element`.

These subtleties of the language currently require careful consideration to
understand.

## Proposed solution

For declaring associated types, replace the `typealias` keyword with `associated`.

This solves the issues mentioned above:

1. `typealias` can now only be used for type aliases declaration.
2. Beginners are now forced to learn about associated types when creating protocols.
3. An error message can now be displayed when someone tries to create a type alias
inside a protocol.

This eliminates the confusion showed in the previous code snippets.

```swift
protocol Prot {
    associated Container : SequenceType
    typealias Element = Container.Generator.Element // error: cannot declare type alias inside protocol, use protocol extension instead
}
```

```swift
protocol Prot {
    associated Container : SequenceType
}
extension Prot {
    typealias Element = Container.Generator.Element
}
```

Alternative keywords considered: `withtype`, `associatedtype`, `typeassociation`, `type`

## Proposed Approach

For declaring associated types, I suggest adding `associated` and deprecating 
`typealias` in Swift 2.2, and removing `typealias` entirely in Swift 3.

## Impact on existing code

As it simply replaces one keyword for another, the transition to `associated`
could be easily automated without any risk of breaking existing code.

## Community Responses

- "I think this is a great idea; re-using typealias for associated types was a mistake." -John McCall
- "Agreed." -Chris Lattner
- "+1 to the proposal, emphasizing the distinction is important; and I
like "associated" as the keyword for this purpose, too." -Dmitri Gribenko
- "+1 for using a distinct keyword for associated types" -Ilya Belenkiy
