# Enum Case Blocks

* Proposal: SE-XXXX
* Authors: [Tim Shadel](https://github.com/timshadel)
* Review Manager: TBD
* Status: **TBD**

## Motivation

Add an optional syntax to declare all code related to a single `case` in one spot. For complex `enum`s, this makes it easier to ensure that all the pieces mesh coherently across that one case, and to review all logic associated with a single `case`. This syntax is frequently more verbose in order to achieve a more coherent code structure, so its use will be most valuable in complex enums.

Swift-evolution thread: [Consolidate Code for Each Case in Enum](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170102/thread.html#29966), [second week discussion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170109/thread.html#30041)

## Proposed solution

Allow an optional block directly after the `case` declaration on an `enum`. Construct a hidden `switch self` statement for each calculated value or `func` defined in any case block. Use the body of each such calculated value in the hidden `switch self` under the appropriate case. Because switch statements must be exhaustive, the calculated value or `func` must be defined in each case block to avoid an error. To reference an associated value within any of the items in a case block requires the value be labeled, or use a new syntax `case(_ label: Type)` to provide a local-only name for the associated value.

## Examples

All examples below are evolutions of this simple enum.

```swift
enum AuthenticationState {
    case invalid
    case expired(Date)
    case validated(token: String)
}
```

### Basic example

First, let's add `CustomStringConvertible` conformance to our enum.

```swift
enum AuthenticationState: CustomStringConvertible {

    case invalid {
        var description: String { return "Authentication invalid." }
    }

    case expired(_ expiration: Date) {
        var description: String { return "Authentication expired at \(expiration)." }
    }

    case validated(token: String) {
        var description: String { return "The authentication token is \(token)." }
    }

}
```

This is identical to the following snippet of Swift 3 code:

```swift
enum AuthenticationState: CustomStringConvertible {

    case invalid
    case expired(Date)
    case validated(token: String)

    var description: String {
        switch self {
        case .invalid:
            return "Authentication invalid."
        case let .expired(expiration):
            return "Authentication expired at \(expiration)."
        case let .validated(token):
            return "The authentication token is \(token)."
        }
    }

}
```

### Extended example

Now let's have our enum conform to this simple `State` protocol, which expects each state to be able to update itself in reaction to an `Event`. This example begins to show how this optional syntax give better coherence to the enum code by placing code related to a single case in a single enclosure.

```swift
protocol State {
    mutating func react(to event: Event)
}

enum AuthenticationState: State, CustomStringConvertible {

    case invalid {
        var description: String { return "Authentication invalid." }

        mutating func react(to event: Event) {
            switch event {
            case let login as UserLoggedIn:
                self = .validated(token: login.token)
            default:
                break
            }
        }
    }

    case expired(_ expiration: Date) {
        var description: String { return "Authentication expired at \(expiration)." }

        mutating func react(to event: Event) {
            switch event {
            case let refreshed as TokenRefreshed:
                self = .validated(token: refreshed.token)
            default:
                break
            }
        }
    }

    case validated(token: String) {
        var description: String { return "The authentication token is \(token)." }

        mutating func react(to event: Event) {
            switch event {
            case let expiration as TokenExpired:
                print("Expiring token: \(token)")
                self = .expired(expiration.date)
            case _ as TokenRejected:
                self = .invalid
            case _ as UserLoggedOut:
                self = .invalid
            default:
                break
            }
        }
    }

}
```

This becomes identical to the following Swift 3 code:

```swift
enum AuthenticationState: State, CustomStringConvertible {

    case invalid
    case expired(Date)
    case validated(token: String)

    var description: String {
        switch self {
        case .invalid:
            return "Authentication invalid."
        case let .expired(expiration):
            return "Authentication expired at \(expiration)."
        case let .validated(token):
            return "The authentication token is \(token)."
        }
    }

    mutating func react(to event: Event) {
        switch self {
        case .invalid: {
            switch event {
            case let login as UserLoggedIn:
                self = .validated(token: login.token)
            default:
                break
            }
        }
        case let .expired(expiration) {
            switch event {
            case let refreshed as TokenRefreshed:
                self = .validated(token: refreshed.token)
            default:
                break
            }
        }
        case let .validated(token) {
            switch event {
            case let expiration as TokenExpired:
                print("Expiring token: \(token)")
                self = .expired(expiration.date)
            case _ as TokenRejected:
                self = .invalid
            case _ as UserLoggedOut:
                self = .invalid
            default:
                break
            }
        }
    }

}
```

### Mixed use example

Let's tackle an example where certain properties make sense in the traditional syntax, and others are cleaner in a case block.

```swift
enum UserMessage {

    case status(_ message: String) {
        var description: String { return "status: \(message)" }
        func render(in vc: UIViewController) { /* status code */ }
    }

    case info(_ message: String) {
        var description: String { return "Info: \(message)" }
        func render(in vc: UIViewController) { /* info code */ }
    }

    case error(title: String, body: String) {
        var description: String { return "ERROR [\(title)]: \(body)" }
        func render(in vc: UIViewController) { /* error code */ }
    }

    var tintColor: UIColor {
        switch self {
        case .error:
            return .red
        default:
            return .blue
        }
    }

}
```

Is identical to this Swift 3 code:

```swift
enum UserMessage {

    case invalid
    case expired(Date)
    case validated(token: String)

    var description: String {
        switch self {
        case let .status(message):
            return "status: \(message)"
        case let .info(message):
            return "Info: \(message)"
        case let .error(title, body):
            return "ERROR [\(title)]: \(body)"
        }
    }

    func render(in vc: UIViewController) {
        switch self {
        case .status:
            /* status code */
        case .info:
            /* info code */
        case .error:
            /* error code */
        }
    }

    var tintColor: UIColor {
        switch self {
        case .error:
            return .red
        default:
            return .blue
        }
    }

}
```

### Error examples

Finally, here's what happens when a case fails to add a block.

```swift
enum AuthenticationState: CustomStringConvertible {

    case invalid  <<< error: description must be exhaustively defined. Missing block for case .invalid.

    case expired(Date)  <<< error: description must be exhaustively defined. Missing block for case .expired.

    case validated(token: String) {
        var description: String { return "The authentication token is \(token)." }
    }

}
```

Defining a `func` or calculated value both within and outside of a case block is not allowed.

```swift
enum AuthenticationState: CustomStringConvertible {

    case invalid
    case expired(Date)
    case validated(token: String) {
        var description: String { return "The authentication token is \(token)." }  <<< error: description must be defined for the entire enum, or within each case block, but not both.
    }

    var description: String {  <<< error: description must be defined for the entire enum, or within each case block, but not both.
        switch self {
        case .invalid, .expired:
            return "Invalid or expired state."
        default:
            return ""
        }
    }

}
```

## Source compatibility

No source is deprecated in this proposal, so source compatibility should be preserved.

## Effect on ABI stability

Because the generated switch statement should be identical to one that can be generated with Swift 3, I don't foresee effect on ABI stability.

Question: does the error case above affect ABI requirements, in order to display the error at the correct case line?

## Alternatives considered

Use of the `extension` keyword was discussed and quickly rejected for numerous reasons.

Defining a default case in a `func` or calculated value outside a case block was dicussed and discarded. While this allows some instances to have less code, this proposal generally trades a slight increase in code verbosity for a bigger gain in code clarity. Existing syntax is great for saving space, and should be used in those situations.
