# Enum case stored properties

* Proposal: TBD
* Author: [Janis Kirsteins](https://github.com/kirsteins)
* Status: TBD
* Review manager: TBD

## Introduction

This proposal allows each enum to have stored properties that are shared among cases.

## Motivation

Enums cases can have a lot of constant (or variable) static values associated with it. For example, planets can have mass, radius, age, closest star etc. Currently there is no way to set or get those values easily.

Example below shows that is hard to read and manage static associated values with each case. It is hard to add or remove case as it would require to add or remove code in four different places in file. Also static associated value like `UIBezierPath` is recreated each time the property is computed while it's constant.

```swift
enum Suit {
    case spades
    case hearts
    case diamonds
    case clubs

    var simpleDescription: String {
        switch self {
        case .spades:
            return "spades"
        case .hearts:
            return "hearts"
        case .diamonds:
            return "diamonds"
        case .clubs:
            return "clubs"
        }
    }

    var color: UIColor {
        switch self {
        case .spades:
            return .blackColor()
        case .hearts:
            return .redColor()
        case .diamonds:
            return .redColor()
        case .clubs:
            return .blackColor()
        }
    }

    var symbol: String {
        switch self {
        case .spades:
            return "♠"
        case .hearts:
            return "♥"
        case .diamonds:
            return "♦"
        case .clubs:
            return "♣"
        }
    }

    var bezierPath: UIBezierPath {
        switch self {
        case .spades:
            let bezierPath = UIBezierPath()
            // add commands to bezierPath ...
            return bezierPath
        case .hearts:
            let bezierPath = UIBezierPath()
            // add commands to bezierPath ...
            return bezierPath
        case .diamonds:
            let bezierPath = UIBezierPath()
            // add commands to bezierPath ...
            return bezierPath
        case .clubs:
            let bezierPath = UIBezierPath()
            // add commands to bezierPath ...
            return bezierPath
        }
    }
}
```

## Proposed solution

Support stored properties for enum cases just as each case were an instance. Case properties are initialized block after each case declaration.

```swift
enum Suit {
    let simpleDescription: String
    let color: UIColor
    let symbol: String
    let bezierPath: UIBezierPath

    case spades {
        simpleDescription = "spades"
        color = .blackColor()
        symbol = "♠"
        let bezierPath = UIBezierPath()
        // add commands to bezierPath ...
        self.bezierPath = bezierPath
    }

    case hearts {
        simpleDescription = "hearts"
        color = .redColor()
        symbol = "♥"
        let bezierPath = UIBezierPath()
        // add commands to bezierPath ...
        self.bezierPath = bezierPath
    }

    case diamonds {
        simpleDescription = "diamonds"
        color = .redColor()
        symbol = "♦"
        let bezierPath = UIBezierPath()
        // add commands to bezierPath ...
        self.bezierPath = bezierPath
    }

    case clubs {
        simpleDescription = "clubs"
        color = .blackColor()
        symbol = "♣"
        let bezierPath = UIBezierPath()
        // add commands to bezierPath ...
        self.bezierPath = bezierPath
    }
}

let symbol = Suit.spades.symbol // "♠"
```

The proposed solution improves:
- Readability as cases are closer with their related data;
- Improves code maintainability as a case can be removed or added in one place;
- Improved performance as there is no need to recreate static values;
- ~30% less lines of code in given example.

## Detailed design

#### Stored properties

Enum stored properties are supported the same way they are supported for structs can classes. Unlike enum associated values, stored properties are static to case and are shared for the same case.

Properties are accessed:
```swift
let simpleDescription = Suit.spades.simpleDescription
```

Mutable properties can be set:
```swift
Suit.spades.simpleDescription = "new simple description"
```

#### Initialization

If enum has uninitialized stored property it must be initialized in a block after each case declaration. The block work the same way as struct initialization. At the end of initialization block all properties must be initialized.

```swift
enum Suit {
    var simpleDescription: String

    case spades {
        simpleDescription = "spades"
    }
}
```

Initialization block can be combine with use of `rawValue`:

```swift
enum Suit: Int {
    var simpleDescription: String

    case spades = 1 {
        simpleDescription = "spades"
    }
}
```
or associated values of the case:

```swift
enum Suit {
    var simpleDescription: String

    case spades(Int) {
        simpleDescription = "spades"
    }
}
```

## Impact on existing code

Stored properties for enums are not currently not supported, so there is no impact on existing code.

## Alternatives considered

- Use labeled tuple as `rawValue` of the enum case [details](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160523/018878.html). Currently `rawValue` has to be compile time constant and has to support Objective-C and C interpolation. Also `rawValue` can reliably be used as enum value when serialized. These two factors make this approach not a perfect solution to this problem. 
- Use per case initializer like [Java Enum](https://docs.oracle.com/javase/tutorial/java/javaOO/enum.html). Swift enum uses custom initializer syntax to setup instances, not cases. So this approach is not suitable for Swift.
