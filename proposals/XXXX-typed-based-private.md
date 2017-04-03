# Type-based Private Access Level

* Proposal: [SE-XXXX](XXXX-typed-based-private.md)
* Authors: [David Hart](http://github.com/hartbit)
* Review Manager: TBD
* Status: TBD

## Introduction

This proposal extends the visibility of the `private` access level to all extensions, declarations and nested types in the same file.

## Motivation

Proposal [SE-0025](0025-scoped-access-level.md) introduced a lexically-scoped access level named `private` and renamed the file-based access level to `fileprivate`. The hope was for `private` to be a good default for restricting visibility further than the whole module and for `fileprivate` to be used in rarer occasions when that restriction needed to be loosened.

Unfortunately, that goal of the proposal has not been realized: Swift's reliance on extensions as a grouping and conformance mechanism has made `fileprivate` more necessary than expected and has caused more friction between `private` and `fileprivate` than intended.

As a consequence, experience with using Swift 3 has caused mixed reactions from the mailing list and greater Swift community, culminating in proposal [SE-0159](0159-fix-private-access-levels.md) which suggested reverting the access level changes. That proposal was rejected to continue supporting the code written since Swift 3 which benefits from the distinction between `private` and `fileprivate`, but it was recognized that the language's lack of a good default access level more restictive than `internal` was unfortunate.

In the hopes of fulfilling the initial goal of [SE-0025](0025-scoped-access-level.md), this proposal defines the visibility of the `private` access level to extensions, declarations and nested types of the member's type in the same file to increase its usefulness and as a good default private access level. `fileprivate` then logically achieves its intended goal of being more rarely used and adheres to Swift's "progressive disclosure” philosophy.

## Detailed design

The design of this proposal defines the visibility of a `private` member declared within a type `X` or an extension of type `X` to:

    * the declaration of `X` if it occurs in the same file
    * all extensions of `X` or subclasses of `X` in the same file
    * all declarations of nested types of `X` in the same file
    * all extensions of nested types of `X` in the same file

To illustrate the consequence of those rules, the following examples will be used with two files in the same module:

### Person.swift

```
struct Person {
    let name: String
    let gender: Gender
    private let age: String

    var greeting {
        return "Hello, my name is \(name)"
    }

    init(name: String, gender: Gender, age: String) {
        self.name = name
        self.age = age
    }

    func greet() {
        // age is accessible because it is defined in the same declaration but secreyAge is not because it is defined
        // in a nested type so the following piece of code would generate a compilation error:
        // if age < gender.secrecyAge {
        // instead:
        if Gender.shouldRevealAge(self) {
            // fullGreeting is accessible because it is defined in an
            // extension of the same type in the same file
            print(fullGreeting)
        } else {
            print(greeting)
        }
    }
}

// private at the top-level scope continues to be equivalent to fileprivate
private extension Person {
    // fullGreeting is implictly private due to the extension's modifier
    var fullGreeting: String {
        // age is accessible because it is defined in the declaration of the extension's type in the same file
        return "Hello, my name is \(name), I'm \(age) years old."
    }
}

extension Person {
    enum Gender {
        case male
        case female

        private var secrecyAge {
            switch self {
            case .male: return 60
            case .female: return 50
            }
        }

        static func shouldRevealAge(_ person: Person) -> Bool {
            // age is accessible because we are in the declaration of a nested type that declared age
            return person.age < person.gender.secrecyAge
        }
    }
}

extension Gender {
    static func leakAge(of person: Person) {
        // age is accessible because we are in the extension of a nested type in the same file
        return person.age
    }
}
```

### Other.swift

```
extension Person : CustomStringConvertible {
    var desription: String {
        return fullGreeting
        // error: fullGreeting is not available because it is defined in another file
    }
}
```

## Source compatibility

Incoming...

## Alternatives Considered

Incoming...