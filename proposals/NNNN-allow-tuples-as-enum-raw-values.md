# Feature name

* Proposal: [SE-NNNN](NNNN-allow-tuples-as-enum-raw-values.md)
* Authors: [Haravikk](https://github.com/haravikk)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

This proposal is simply that tuples be permitted as raw values within enum types, allowing multiple, default values to be easily assigned to enum cases.

Swift-evolution thread: [Discussion thread topic](https://lists.swift.org/pipermail/swift-evolution/)

## Motivation

Currently the raw values for enum cases support a range of literal types, but this does not include tuples, which limits these to only single values, or requires the use of more complex `RawRepresentable` boilerplate to assign multiple values to each case. The alternative is to use a switch, however this can become cumbersome very quickly, for example:

```
enum Colour {
    case Red, Yellow, Green, Cyan, Blue, Magenta
    
    var components:(red:Int, green:Int, blue:Int) {
        switch(self) {
            case red: return (255, 0, 0)
            case yellow: return (255, 255, 0)
            case green: return (0, 255, 0)
            case cyan: return (0, 255, 255)
            case blue: return (0, 0, 255)
            case magenta: return (255, 0, 255)
        }
    }
    
    var red:Int { return self.components.red }
    var green:Int { return self.components.green }
    var blue:Int { return self.components.blue }
}
```

This is unwieldy becaue of the separatation of the values from the cases themselves, though the switch at least catches any new cases that have been filled out.

## Proposed solution

The proposed solution is simply to allow tuples to fill this gap in enum raw values, allowing multiple values to be assigned easily to each enum case without the overhead of a `RawRepresentable` implementation.

Here's the above example re-written using a tuple raw value instead:

```
enum Colour : (red:Int, green:Int, blue:Int) {
    case Red = (255, 0, 0)
    case Yellow = (255, 255, 0)
    case Green = (0, 255, 0)
    case Cyan = (0, 255, 255)
    case Blue = (0, 0, 255)
    case Magenta = (255, 0, 255)
    
    var red:Int { return self.rawValue.red }
    var green:Int { return self.rawValue.green }
    var blue:Int { return self.rawValue.blue }
}
```

## Detail Design

The main hurdle for this issue is the handling of tuple equality. Currently in Swift an equality operator is produced automatically for any tuple type for which all of its components are `Equatable`, however as a non-nominal type the tuples themselves are not themselves considered to be `Equatable`.

The result of this is that either this proposal needs to wait until tuples are given the ability to conform (as thus be truly `Equatable`) or for the proposal to be implemented sooner with some kind of hack that enables tuples to be treated as `Equatable` to enable them to be used. Clearly the first would be the preferred option, but it will depend upon what the time-frame for it may be.

## Source compatibility

Purely additive.

## Alternatives considered

This proposal was inspired by discussion on the topic of adding stored properties to enums, however this would require more significant new syntax and behaviour, while most use-cases that it could solve should be well covered by the simpler option of adding tuple raw values as a first step.
