# Factory Initializers

* Proposal: SE-NNNN
* Author: [Riley Testut](http://twitter.com/rileytestut)
* Status: **Awaiting review**
* Review Manager: TBD

## Introduction

This proposal seeks to add an additional type of initializer to the Swift language, a factory initializer, to compliment the existing required and convenience initializers. Unlike these other initializers, a factory initializer will allow for returning an instance of a type directly that either conforms to or is a subtype of the type declaring the factory initializer.

Swift-evolution thread: [[Proposal] Factory Initializers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/003192.html)

## Motivation

The "factory" pattern is common in many languages, including Objective-C. Essentially, instead of initializing a type directly, a method is called that returns an instance of the appropriate type determined by the input parameters. Functionally this works well, but ultimately it forces the client of the API to remember to call the factory method instead, rather than the type's initializer. This might seem like a minor gripe, but given that we want Swift to be as approachable as possible to new developers, I think we can do better in this regard.

## Proposed solution

Rather than have a separate factory method, I propose we build the factory pattern right into Swift, by way of specialized “factory initializers”. The exact syntax was proposed by Philippe Hausler from a [previous Swift-Evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001328.html), and I think it is an excellent solution:

    public class AbstractBase {
		    
		private init(type: InformationToSwitchOn) {}
    
        public factory init(type: InformationToSwitchOn) {
            if … {
                return ConcreteImplementationOne(type)
            }
            else {
                return ConcreteImplementationTwo(type)
            }
        }
    }

    class ConcreteImplementationOne : AbstractBase {}
    class ConcreteImplementationTwo : AbstractBase {}

Unlike the existing Swift initializers, an instance of a type can be returned directly from the factory initializer. This is similar to Objective-C’s handling of initializers, and allows for more flexibility.

Additionally, factory initializers should be available for protocols as well, such as the following instance:

    public protocol MyProtocol {
        public factory init(type: InformationToSwitchOn) {
            return ConformingStruct(type)
        }
    }

    private struct ConformingStruct: MyProtocol {
        init(type: InformationToSwitchOn) {}
    }

This would allow developers to expose a protocol, and provide a way to instantiate a “default” type for the protocol, without having to also declare the default type as public. This is similar in part to instantiating an anonymous class conforming to a particular interface in Java.

## Examples

__Class Cluster/Abstract Classes__  
This was the reasoning behind the original proposal, and I still think it would be a very valid use case. The public superclass would declare all the public methods, and could delegate off the specific implementations to the private subclasses. Alternatively, this method could be used as an easy way to handle backwards-compatibility: rather than litter the code with branches depending on the OS version, simply return the OS-appropriate subclass from the factory initializer. Very useful.

__Initializing Storyboard-backed View Controller__  
This is more specific to Apple Frameworks, but having factory initializers could definitely help here. Currently, view controllers associated with a storyboard must be initialized from the client through a factory method on the storyboard instance (storyboard.instantiateViewControllerWithIdentifier()). This works when the entire flow of the app is storyboard based, but when a single storyboard is used to configure a one-off view controller, having to initialize through the storyboard is essentially use of private implementation details; it shouldn’t matter whether the VC was designed in code or storyboards, ultimately a single initializer should “do the right thing” (just as it does when using XIBs directly). A factory initializer for a View Controller subclass could handle the loading of the storyboard and returning the appropriate view controller.

## Impact on existing code

This proposal will have no impact on existing code. This will only add an additional way to instantiate types.

## Alternatives considered

* Keep the Swift initialization pattern as-is. The Swift initialization pattern can already be somewhat complex (due in no part to Objective-C’s influence), and adding another rule to it can potentially confuse newcomers even more. That being said, there is currently no way to accomplish certain tasks, such as a class cluster pattern, in pure Swift without this addition.

* Limit factory initializers to classes/structs. This would work, but I believe there are some genuine benefits to allowing factory initializers on protocols as well. Because they simply return values, I don’t see a reason to *not* include them for protocols, in order to keep the initialization patterns as uniform as possible.

## Comments from Swift-Evolution

__Philippe Hausler <phausler@apple.com>__  
I can definitely attest that in implementing Foundation we could have much more idiomatic swift and much more similar behavior to the way Foundation on Darwin actually works if we had factory initializers. 

__Brent Royal-Gordon <brent@architechies.com>__  
A `protocol init` in a protocol extension creates an initializer which is *not* applied to types conforming to the protocol. Instead, it is actually an initializer on the protocol itself. `self` is the protocol metatype, not an instance of anything. The provided implementation should `return` an instance conforming to (and implicitly casted to) the protocol. Just like any other initializer, a `protocol init` can be failable or throwing.

Unlike other initializers, Swift usually won’t be able to tell at compile time which concrete type will be returned by a protocol init(), reducing opportunities to statically bind methods and perform other optimization tricks. Frankly, though, that’s just the cost of doing business. If you want to select a type dynamically, you’re going to lose the ability to aggressively optimize calls to the resulting instance.
