# Possibility to makes classes partial as C# language.

* Proposal: [SE-0006](https://github.com/djnivek/swift-evolution/proposals/0008-makes-swift-class-struct-definitions-partial.md)
* Author(s): [Kevin Machado](https://github.com/djnivek)
* Status: **Proposition**
* Review manager: Unknown

## Introduction

In swift we are able to add `extension` of classes that allows us to add methods but we cannot add attributes, properties.
`C# language` allows developers to make its *classes **partial***. It is possible to *split the definition of class, struct or interface over two or more source files*.
Could we make swift able to do this stuff ?

## Proposed solution

Add `partial` keyword to alert the compiler that this class is splited over one or more source files.

**Example**

```swift
  // Common logic for bank model
  partial class Bank {

    var amount: Int

    init() {
        amount = 0
        super.init()
    }

    func withdraw(amount amount: Int) {
        self.amount -= amount
    }

  }

  // Business logic for customer within bank model
  partial class Bank {

    unowned let owner: Customer

    init(customer: Customer) {
        self.owner = customer
    }

    func notifyCustomer() {
        // some code
    }

  }
```

**More changes will be summarized here as they are implemented.**

## Alternative solution

We also could add more feature with the `extension` paradigm. Adding properties, attributes and more directly on the *extension scope*.
