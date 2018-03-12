# Feature name

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Michael Isasi](https://github.com/Jetmax25)
* Review Manager: TBD
* Status: **Awaiting Review**

## Introduction

Default parameters within overridden functions in swift need to behave consistently. When a superclass or protocol function 
is overridden the new default parameter value should also override the previous default value. At the very least parameter overrides 
should keep consistent behavior between class extensions and protocol implementations


Swift-evolution thread: [Allow default parameter overrides](https://forums.swift.org/t/pitch-allow-default-parameter-overrides/10673)

## Motivation

The current system of overriding functions with default parameters behaves in a way that is counter to developer expectations.
In addition classes and protocols handle default parameters in different ways which causes more inconsistent behavior. 

**Protocol Implementation**
    protocol OverridePrintProtocol {
        func printTest(param : String)
    }

    extension OverridePrintProtocol {
        func printTest(param : String = "Ex Default") {
            print("Extension logic: \(param)")
        }
    }

    class ImplementationClass : OverridePrintProtocol {
        func printTest(param : String = "Class Default") {
            print("Class logic: \(param)")
        }
    }

    let overrideTest : OverridePrintProtocol = ImplementationClass.init() 
    overrideTest.printTest() // Prints: ”Extension logic: Ex Default”
    overrideTest.printTest(param: "Injected String") // Prints: "Class logic: Injected String"
    
The above code demonstrates what happens when a protocol extension defines a function with a default parameter, and a class
implements the protocol, overriding the function. 

If there is no parameter provided then the both the extension logic and the extension default value are use, completely ignoring the override. However, if there is a provided value, the class logic overrides. This is sure to cause issues with developers, as there is no reason to ever intend fo this behavior.

This creates a situation where it is never a good idea to use default parameters with protocols

This is currently the safest method for achieving default params as of swift 4. 

     protocol OverridePrintProtocol {
        var param { get }
        func printTest(param : String)
    }

    extension OverridePrintProtocol {
        var param : String {
          return "Ex Default"
        }
        func printTest(param : String?) {
            print("Extension logic: \(param ?? self.param)")
        }
    }

    class ImplementationClass : OverridePrintProtocol {
        var param : String {
          return "Implementation Default"
        }
        func printTest(param : String?) {
            print("Class logic: \(param)")
        }
    }
    
However it is extremely cumbersome as a value must be created for each default parameter. Not only that but the variable is strongly tied to the function and not used outside of it. This is extremely bloated and unnessesary.
    
**Class Extension**

    class MySuperClass {
        func printStatement( statement : String = "Super Default") {
            print( "Super Logic: \(statement)")
        }
    }

    class MySubClass : MySuperClass {
        override func printStatement( statement : String = "Sub Default") {
            print( "Sub Logic: \(statement)")
        }
    }

    let classInstance : MySuperClass = MySubClass.init()
    classInstance.printStatement() // Prints: "Sub Logic: Super Default" 
    classInstance.printStatement("Injected String") // Prints "Sub Logic: Injected String"
    
Here when a class is extended in both instances the subclass logic is executed with the superclass default value. The default value for the subclass will never be used, and the developer is given no warning that this is the case

## Proposed solution

In all cases the swift compiler should override the default parameter values with that of the subclasses/protocol implementation. This would provide a logical execution of code to the developer as well as give the developer more options when creating classes

## Detailed design

All default parameters should have the same logic as if the parameter was defined outside the scope as shown in #Motivation.  Whenever a function is overridden the new default parameter value is the one defined in the function. If there is no default value given with the function then the superclass default value is used. 

Depending on how Swift reads signatures it may be necessary to specify in the protocol that a function's signature contains a default value for a parameter. This could potentially be done with the keyword "dynamic"

     protocol OverridePrintProtocol {
        func printTest(param : String = dynamic)
    }

This type of change however should be its own proposal so long as default parameter overrides are available without such a change

## Source compatibility
Minimal/None: It is hard to imagine that any developer would rely on the current logic with default parameters, therefore there should be no issues when the new logic is implemented

## Effect on ABI stability
Minimal/None: It is hard to imagine that any developer would rely on the current logic with default parameters, therefore there should be no issues when the new logic is implemented


## Effect on API resilience
Minimal/None: It is hard to imagine that any developer would rely on the current logic with default parameters, therefore there should be no issues when the new logic is implemented

## Alternatives considered

The bare minimum change should be warnings given to the developer. All overridden functions that contain a default parameter value should inform the developer that the subclass value will be used, and the protocol extension logic will be executed


