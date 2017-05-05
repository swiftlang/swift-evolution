# Generic and Throwing Subscripts

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author: [Harlan Haskins](https://github.com/harlanhaskins) and [Robert Widmann](https://github.com/codafi)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction
Currently, subscripts cannot be declared `[re]throws` and cannot declare new generic parameters.
There isn't a clear reason why they aren't as capable as full-fledged functions, so we propose
adding generic constraints and throwing semantics to subscripts.

## Motivation

On the throwing side, currently there are two ways to express a failing subscript:
 - Return an `Optional`, failing with `nil`.
 - Call `fatalError(_:)` on failure.

Both of these throw out useful information about the cause of the underlying error that using Swift's error handling mechanism can otherwise provide.

As for generics, to take an example, it has become a common pattern among JSON decoding DSL libraries to express a throwing generic extension on `Dictionary` like so

```swift
extension Dictionary {
    public func parse<T>(key: Key) throws -> T {
        guard let value = self[key] else {
            throw JSONError.MissingKey("\(key)")
        }
        guard let ofType = value as? T else {
            throw JSONError.InvalidKey(key: "\(key)", expectedType: T.self, foundType: value.dynamicType)
        }
        return ofType
    }
}

public enum JSONError: ErrorType, CustomStringConvertible {
    case InvalidKey(key: String, expectedType: Any.Type, foundType: Any.Type)
    case MissingKey(String)
    public var description: String {
        switch self {
        case .InvalidKey(let key, let expected, let found):
            return "Invalid key \"\(key)\". Expected value of type \"\(expected)\", found \"\(found)\"."
        case .MissingKey(let key):
            return "Key \(key) not found."
        }
    }
}
```

Given this, one can decode JSON with the full support of native type inference and exception handling.  But when working with the DSL, one would expect to be able to express this as a subscript on `Dictionary`, allowing the following:

```swift
//...

extension Dictionary {
    public subscript<T>(key: Key) throws -> T {
        guard let value = self[key] else {
            throw JSONError.MissingKey("\(key)")
        }
        guard let ofType = value as? T else {
            throw JSONError.InvalidKey(key: "\(key)", expectedType: T.self, foundType: value.dynamicType)
        }
        return ofType
    }
}
```

We believe this is an even more natural way to write these kinds of libraries in Swift and that bringing subscript member declarations up to par with functions is a useful addition to the language as a whole.

## Proposed solution

Add the ability to introduce new generic parameters and mark `throws` on subscript members.

## Detailed design

This change will modify and add the following productions in the Swift grammar

```diff
GRAMMAR OF A SUBSCRIPT DECLARATION

subscript-declaration → subscript-head subscript-result code-block
subscript-declaration → subscript-head subscript-result getter-setter-block
subscript-declaration → subscript-head subscript-result getter-setter-keyword-block
-subscript-head → attributes(opt) declaration-modifiers(opt) subscript parameter-clause
+subscript-head → attributes(opt) declaration-modifiers(opt) generic-parameter-clause(opt) subscript parameter-clause
+subscript-result → -> attributes(opt) throws(opt) type
+subscript-result → -> attributes(opt) rethrows(opt) type
```

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.

