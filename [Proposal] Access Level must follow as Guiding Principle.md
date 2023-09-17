# [Proposal] Access Level must follow as Guiding Principle

- Proposal: [SE-NNNN](notion://www.notion.so/jjong-my/NNNN-filename.md)
- Authors: [shlim(JJong)](https://github.com/shlim0)
- Review Manager: TBD
- Status: **Awaiting review**
- Review: ([pitch](https://forums.swift.org/...))

## Introduction

In the *access control* document, the description of *Custom Types* and *default initializer* that I think incorrect.

## Motivation

https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol#Custom-Types

When I saw above document for *Access Control* that had a strange things. I saw some **Example 1.** like that.

### Example 1.

```swift
public class SomePublicClass {                  // explicitly public class
    public var somePublicProperty = 0            // explicitly public class member
    var someInternalProperty = 0                 // implicitly internal class member
    fileprivate func someFilePrivateMethod() {}  // explicitly file-private class member
    private func somePrivateMethod() {}          // explicitly private class member
}

class SomeInternalClass {                       // implicitly internal class
    var someInternalProperty = 0                 // implicitly internal class member
    fileprivate func someFilePrivateMethod() {}  // explicitly file-private class member
    private func somePrivateMethod() {}          // explicitly private class member
}

fileprivate class SomeFilePrivateClass {        // explicitly file-private class
    func someFilePrivateMethod() {}              // implicitly file-private class member
    private func somePrivateMethod() {}          // explicitly private class member
}

private class SomePrivateClass {                // explicitly private class
    func somePrivateMethod() {}                  // implicitly private class member
}
```

According to above example, it looks like some *******class******* has some *Access Level* and *class member* of that *class* has equal or more restrictive *Access Level.* But It’s not true. **Example 2.** below builds successfully.

### Example 2.

```swift
public class SomePublicClass {
    open var someOpenProperty = 0
    
    open func someOpenMethod() {}
}

class SomeInternalClass {
    open var someOpenProperty = 0
    public var somePublicProperty = 0
    
    open func someOpenMethod() {}
    public func somePublicMethod() {}
}

fileprivate class SomeFilePrivateClass {
    open var someOpenProperty = 0
    public var somePublicProperty = 0
    internal var someInternalProperty = 0
    
    open func someOpenMethod() {}
    public func somePublicMethod() {}
    internal func someInternalMethod() {}
}

private class SomePrivateClass {
    open var someOpenProperty = 0
    public var somePublicProperty = 0
    internal var someInternalProperty = 0
    fileprivate var someFileprivateProperty = 0
    
    open func someOpenMethod() {}
    public func somePublicMethod() {}
    internal func someInternalMethod() {}
    fileprivate func someFilePrivateMethod() {}
}
```

I learned that **internal entities are affected by the access level of external entities.** The reasons are as follows.

https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/#Guiding-Principle-of-Access-Levels

Note, however, in the case of inheritance, class members in the *subclass* can override to a higher level, even if the class members in the *superclass* have more restrictive access controllers.

https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol#Subclassing

And also, I caught one more thing that I thought was a problem.

### Example 3.

```swift
private class PrivateClass {     // explicitly private class
    private var epp = 0          // explicitly private property
    var ipp = 0                  // implicitly private property
}

PrivateClass().epp
PrivateClass().ipp
```

According to **Example 1**, variables `epp` and `ipp` must be private type. Because the external entity `PrivateClass` is private, the internal entity that follows it is implicitly a private type. Therefore, the variable `epp` or the variable `ipp` should not be accessible. But the compiler takes it differently. The result of this is follow as **Figure 1.**

### Figure 1.

<img width="666" alt="Untitled" src="https://github.com/shlim0/swift-evolution/assets/46235301/3cc314e7-716b-4377-a6d3-b8bb3230291a">


## Proposed solution

Document for *Access Control* have to notify so specify exceptional cases such as ********Example 2.******** Or it should be fixed contents about *Custom Types.* And also the compiler for *Xcode* must be checked by *Apple*.

## Source compatibility

Using the codes *Access Levels* without following the *Guiding Principle of Access Levels* may not be compiled.

## ABI compatibility

It should not affect ABI compatibility.

## Acknowledgments

Thank you for reading this proposal because I’m not good at writing in English(I’m from Korea).
