# Abstract classes and meythods

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): David Scrève
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

A short description of what the feature is. Try to keep it to a
single-paragraph "elevator pitch" so the reader understands what
problem this proposal is addressing.  

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution)

## Motivation

like pure virtual methods in C++ and abtract classes in Java and C#, frameworks development 
sometimes required abstract classes facility.
An abstract class is like a regular class, but some methods/properties are not implemented 
and must be implemented in one of inherited classes.
An abstract class can inherit from other class, implements protocols and has members 
attributes as opposite from protocols.
Only some methods and properties might be abstract.
The goal of abstract classes is to encapsulate a generic behavior that may need some 
specific implementation methods which are not known in abstract class. This behavior 
requires attributes that are used by internal abstract class method.

Example : 
Considere a generic RESTClient that is included in a framework : 

```swift
class RESTClient {
    
    var timeout = 3000
    
    var url : String {
        assert(false,"Must be overriden")
        return ""
    }
    
    func performNetworkCall() {
        let restURL = self.url
        print("Performing URL call to \(restURL) with timeout \(self.timeout)")
    }
}

```

And an implementation : 
```swift
class MyRestServiceClient : RESTClient {
    override var url : String {
        return "http://www.foo.com/client"
    }
    
}
```

As you can see, url properties must be implemented by inherited class and should not be 
implemented by ancestor.
As workaround, we have added assertion, but this error is only detected at runtime and not 
at compile time and might create crash for end-user.

## Proposed solution
We propose to add a new keyword to indicate that a method or a property is abstract and 
not implemented in current class.
This indicates that method or properties must be implemented in inherited class that can 
be implemented.
We propose the keyword abstract that must be added to class and property/method : 

```swift
abstract class RESTClient {    
     var timeout = 3000

    abstract var url : String { get }
    
    func performNetworkCall() {
        let restURL = self.url
        print("Performing URL call to \(restURL) with timeout \(self.timeout)")
    }
}
```

And an implementation : 
```swift
class MyRestServiceClient : RESTClient {
    override var url : String {
        return "http://www.foo.com/client"
    }
    
}
```

## Detailed design
An abstract class cannot be instanciated. 

If a class contains one or more abstract methods/properties, it must be declared abstract.

A class that inherits from abstract must be declared abstract if it does not implements 
all inherited methods/properties.

If you try to implement an abstract class or a inherited class that implements partially 
abstract methods/properties, you will get a compiler error.

As for override keyword, abstract properties apply on setter, getter and observers. 

When declaring an abstract property, you must specify which methods must be implemented : 
get, set, didSet, willSet. 

If you do not specify anything, only setter and getter are made 
abstracts as below : 

```swift
    abstract var url : String
```

Observers provides default empty implementation.

Type is mandatory for abstract properties since it cannot be inferred.

## Impact on existing code
This change has no impact on existing code, but might change the ABI that is being 
stabilizing in Swift 3.0.

## Alternatives considered
As first reading, it seems that protocols and protocol extensions might fit the need. It 
actually does not because abstract classes can have attributs and properties that 
protocols does not support.

An alternative solution would be to add attributes to protocols and protocol extensions, 
but this might broke compatibility with Objective-C runtime.



