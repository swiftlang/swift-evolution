# Allow trailing commas in parameter lists and tuples

* Proposal: [SE-0084](0084-trailing-commas.md)
* Authors: [Grant Paul](https://github.com/grp), [Erica Sadun](http://github.com/erica)
* Status: **Scheduled for review: May 10...16, 2016**
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

Swift permits trailing commas after the last element in array or dictionary literal. This proposal extends that to parameters and tuples.

Original swift-evolution discussion: [Allow trailing commas in argument lists](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012112.html)


## Motivation

Trailing commas offer linguistic sugar for flexible design. Ignored by the compiler, they enable developers to easily reorder elements and to comment out and uncomment in list-based features on an as-needed basis:

```swift
let strings = [
   "abc",
   "cde",
   "fgh",
//   "ijk",
]
```

Parameter declarations would benefit from the same support. Complex declarations, especially those with defaults, could be moved around and commented without having to spend unnecessary time adjusting where the final comma should and should not appear.

```swift
func padStringToLength(
    sourceString: String,
    destinationCount: Int,
    paddingStyle: StringPaddingStyle = .Left,
    paddingCharacter: Character = " ",
) -> String {
    /* ... */
}

padStringToLength(
    sourceString: "source",
    destinationCount: 4,
    paddingStyle: .Right,
    paddingCharacter: "",
)
```

Tuples would see the same benefits. With trailing commas, reversing the order of this tuple would take just two line-level adjustments:

```swift
let tuple: (
    string: String,
    number: Int,
) = (
   string: "string",
   number: 0,
)
```


## Detailed Design

With this design, the Swift compiler will simply ignore final parameter and tuple commas as it does in collections. This includes function calls, function declarations, tuple type definitions, and tuple literals.

Zero-element tuples and parameter lists would not support trailling commas. Single-element tuples would not allow trailing commas but single-element parameter lists would, consistent with the existing prohibition on named single-element tuples.


## Alternatives Considered

There are no alternatives considered.
