# Multiple Trailing Closures

* Proposal: [SE-NNNN](NNNN-multiple-trailing-closures.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: [apple/swift#29745](https://github.com/apple/swift/pull/29745)

## Introduction

Swift currently supports a special syntax for a single _trailing closure_ which makes it possible to pass a closure
as function's final argument after parentheses as a block without a label. This is very useful when the
closure expression is long. We propose to extend this functionality to cover multiple closures instead of just one.

Swift-evolution thread: [Pitch: Multiple Trailing Closures](https://forums.swift.org/t/pitch-multiple-trailing-closures/33688)

## Motivation

There are numerous real world examples where some function accepts more than one function-type argument.
In cases like that it’s usually ill-advised to use trailing closure syntax because it’s unclear what argument
is used at trailing position, especially if call involves defaulted arguments e.g.

```swift
func transition(with view: View,
                duration: TimeInterval,
                animations: (() -> Void)? = nil,
                completion: (() -> Void)? = nil) {}
transition(with: view, duration: 2.0) {
  print("which arg is this?")
}
```

It's not very clear just by looking at this code which argument is used because both of them are defaulted,
so for readability it's much better to supply a label explicitly:

```swift
transition(with: view, duration: 2.0, completion: { ... })
```

Let's consider a couple of other relatively simple examples:

```swift
func when<T>(_ condition: @autoclosure () -> Bool, then: () -> T, `else`: () -> T) -> T {
  ...
}
```

or **SwiftUI**

```swift
struct Button<Label> where Label : View {
  init(action: () -> Void, label: @ViewBuilder () -> Label) {
    ...
  }
}
```

To form a valid call for each of the aforementioned examples developers could use a mix of regular labeled argument
syntax with trailing closure (with disadvantaged described above) or only argument syntax which becomes cumbersome
and noisy if closures are long or there are too many arguments e.g.

```swift
when(2 < 3, then: {
  ...
  ...
  ...
}) {
  ...
  ...
  ...
}
```

```swift
Button(action: {
  ...
  ...
}) {
  Label("Hello!")
}
```

Such syntax for calls is inconsistent, it introduces unnecessary commas and labels.

## Proposed solution

The problem could be fixed by introduction of a uniform spelling for all labeled function arguments as an extension of existing trailing closure feature/syntax e.g.

```swift
when(2 < 3) {
   then: {
     ...
     ...
   }
   else: {
     ...
     ...
   }
}
```

or (no parentheses necessary since all arguments are closures)

```swift
Button {
  action: {
    ...
    ...
    ...
  }

  label: {
    Label("Hello!")
  }
}
```

Proposed new syntax places all labeled closures involved in the call into a single trailing closure block
that makes it much more human readable and removes a need to delimit calls with commas and parentheses, which is especially important when closures become long.

## Detailed design

Changes required to implement new syntax are constrained solely to the parser, namely to the parsing of call arguments.

It's possible to do an early syntax transformation which would consider each block to be a regular argument and adjust locations of parentheses if necessary.
For type checker perspective this means that calls with new syntax would just be regular calls which require no special handling:

```swift
when(2 < 3) {
   then: { ... }
   else: { ... }
}
```

Would be transformed into:

```swift
when(2 < 3,
    then: { ... },
    else: { ... }
)
```

Since all of the essential source information is preserved (locations of all labels and closure blocks) it would be possible for type-checker to produce diagnostics for invalid code without any changes.

## Source compatibility

This is an additive proposal, which makes ill-formed syntax well-formed but otherwise does not affect existing code.

## Effect on ABI stability

This feature is implementable entirely in the parser, as a syntactic transformation on call expressions. It, therefore, has no impact on the ABI.

## Effect on API resilience

Proposed changes do not introduce features that would become a part of a public API.

## Alternatives considered

It has been mentioned on the forums that it's already possible to imitate proposed syntax by placing labeled arguments on separate lines e.g.

```swift
when(2 < 3,
  then: {
    ...
    ...
  },
  else: {
    ...
    ...
  }
)
```

This is a reasonable critique but spelling like that feels like a workaround to a requirement for arguments to be comma separated especially when some of them are un-labeled just like `condition` in previous example.

