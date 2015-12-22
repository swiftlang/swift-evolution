# Coroutine for Swift

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [SusanDoggie](https://github.com/SusanDoggie)
* Status: **Awaiting Review**
* Review manager: TBD

## Introduction

Coroutine can be used for generate a list of values without creating a array. And it's a useful mechanism for lazy evaluation.

## Motivation

As the following function, which would provide a `AnyGenerator` object to get the results of coroutine.

```swift
func factorialList(var x: Int) -> AnyGenerator<Int> {
    var result = 1
    if x == 0 {
        return
    }
    for counter in 1...x {
        result *= counter
        yield result
    }
}
```

```swift
Array(GeneratorSequence(factorialList(5)))  // [1, 2, 6, 24, 120]
```

## Proposed solution

Swift compiler can convert `yield` to a state machine with closure. the above code is equivalent to:
```swift
func factorialList(var x: Int) -> AnyGenerator<Int> {
    var state = 0
    var result = 1
    var _variable_0001 = (1...x).generate()
    
    let g = anyGenerator { () -> Int? in
        switch state {
            case 0: @goto(State_0)  // jump to start point
            case 1: @goto(State_1)  // jump to State_1
            case -1: return nil
        }
        @label(State_0)
        if x == 0 {
            state = -1; return nil  // end of coroutine
        }
        while let counter = _variable_0001.next() {
            result *= counter
            state = 1; return result  // yield result
            @label(State_1)
        }
        state = -1; return nil  // end of coroutine
    }
    
    return g
}
```

## Detailed design

Describe the design of the solution in detail. If it involves new
syntax in the language, show the additions and changes to the Swift
grammar. If it's a new API, show the full API and its documentation
comments detailing what it does. The detail in this section should be
sufficient for someone who is *not* one of the authors to be able to
reasonably implement the feature.

## Impact on existing code



## Alternatives considered


