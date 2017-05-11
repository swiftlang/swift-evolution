# Feature name

* Proposal: [SE-0008](https://github.com/apple/swift-evolution/blob/master/proposals/0008-external-variable-in-extension.md)
* Author(s): [Swift Developer](https://github.com/chenyunguiMilook)
* Status: **Review**
* Review manager: TBD

## Introduction

Extension for a class is very good, but the limitation is we can not add local
variable to it, some thing is very hard to implement
For example: 

```swift

public class Racer {

    public var name:String
    
    public init(name:String) {
        self.name = name
    }
}

public extension Racer {
    
    public var winTimes:Int {
        // requires access local variable
    }
    
    public func win() {
        // need to update local variable
    }
}

```

## Motivation

If enabled add variable in the extention, will may get these benefit:
- more clean and readable code, easy to manage extensions
- get more flexible code structure
- able to extends system classes with custom attributes

## Proposed solution

- use `external` keyword to define a namespace (it is against to `internal`)
- defined variable in extension default namespace is `external`
- all `external var` need init with a default value
- if same name with class variable, `external` variable will get higher priority
- extension method only can access `external` variable in same scrop

## Detailed design


```swift
public class Racer {

    public var name:String

    public init(name:String) {
        self.name = name
    }
}

public extension Racer {

    external var _winTimes:Int = 0

    public var winTimes:Int {
        return _winTimes
    }

    public func win() {
        _winTimes++
    }
}
```

## Impact on existing code

I think this is addtional feature for swift, will not impact current code.

## Alternatives considered


