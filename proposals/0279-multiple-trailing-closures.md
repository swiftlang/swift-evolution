# Multiple Trailing Closures

* Proposal: [SE-0279](0279-multiple-trailing-closures.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin), [Doug Gregor](https://github.com/douggregor)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Active Review (March 2–11)**
* Implementation: [apple/swift#29745](https://github.com/apple/swift/pull/29745)

## Introduction

Since its inception, Swift has supported _trailing closure_ syntax, which is a bit of syntactic sugar
that makes passing closures more ergonomic. Trailing closures have always had two restrictions that limited their
applicability. First, that any call is limited to a single trailing closure, making the feature awkward or even
unusable when an API has more than one callback. This limitation was noticed 
[very early on in Swift's lifetime](https://www.natashatherobot.com/swift-trailing-closure-syntax/) as "the"
problem with trailing closure syntax.
Second, that a trailing closure argument does not provide an
argument label, which can lead to call sites that are less clear. This proposal removes both restrictions
by providing an unambiguous syntax for providing multiple, labeled trailing closures in a call, leading to
clearer and more consistent code.  

Swift-evolution thread: [Pitch: Multiple Trailing Closures](https://forums.swift.org/t/pitch-multiple-trailing-closures/33688)

## Motivation

Trailing closure syntax helps give more structure to call sites, separating "normal" function arguments,
which describe what a function should do, from "callback" function arguments, which provide user-specified
actions. Consider this example usage of a trailing closure with
[`UIView.animate(withDuration:animations:)`](https://developer.apple.com/documentation/uikit/uiview/1622418-animate),
from Paul Hudson's
"[What is trailing closure syntax?](https://www.hackingwithswift.com/example-code/language/what-is-trailing-closure-syntax)":

```swift
UIView.animate(withDuration: 1) { [unowned self] in
    self.view.backgroundColor = UIColor.red
}
```

This is equivalent to the "desugared" version of the call, which does not use trailing closure syntax:

```swift
UIView.animate(withDuration: 1, animations: { [unowned self] in
    self.view.backgroundColor = UIColor.red
})
```

The version with trailing closure syntax separates out the "configuration" aspects of the animation
(its duration) from the "action" to be taken (update the background color). It also eliminates the unsightly
`})` that can become a major nuisance when nesting calls with callbacks 
(example from [Anupam Chugh](https://www.journaldev.com/22104/ios-uiview-animations)):

```swift
func toggle() {
  UIView.animate(withDuration: 1, animations: {
    self.myView.backgroundColor = UIColor.green
    self.myView.frame.size.width += 50
    self.myView.frame.size.height += 20
    self.myView.center.x += 20
  }, completion: { _ in
    UIView.animate(withDuration: 1, delay: 0.25, options: [.autoreverse, .repeat], animations: {
      self.myView.frame.origin.y -= 20
    })
  })
}
```

This example brings in more of the family of `UIView.animate` APIs that show the limits of trailing closure
syntax. It uses a related API
[`UIView.animate(withDuration:delay:options:animations:completion:)`](https://developer.apple.com/documentation/uikit/uiview/1622451-animate)
that also accepts a completion block. Let's consider that API in isolation, and try to use it
with a trailing closure:

```swift
UIView.animate(withDuration: 0.7, delay: 1.0, options: .curveEaseOut, animations: {
  self.view.layoutIfNeeded()
}) { finished in
  print("Basket doors opened!")
}
```

It is not at all clear that the trailing closure here is meant to be the completion block, especially
because the other `UIView.animate` uses a trailing closure for `animations`.
Concerns about call-site confusion have led to rules about [not using trailing closures when there
are multiple parameters of function type](https://rules.sonarsource.com/swift/RSPEC-2958) and, indeed,
[Ehab Yosry Amer's tutorial on `UIView` animation](https://www.raywenderlich.com/5255-basic-uiview-animation-tutorial-getting-started),
where this code came from, avoids using trailing closures entirely:

```swift
UIView.animate(withDuration: 0.7, delay: 1.0, options: .curveEaseOut, animations: {
  self.view.layoutIfNeeded()
}, completion: { finished in
  print("Basket doors opened!")
})
```

This problem affects many APIs, because having multiple parameters of function type is fairly common.
SwiftUI's `Button`, for example contains an initializer
[`init(action:label:)`](https://developer.apple.com/documentation/swiftui/button/3283501-init):

```swift
struct Button<Label> where Label : View {
  init(action: () -> Void, label: @ViewBuilder () -> Label) {
    ...
  }
}
```

Whether using trailing closures or avoiding them, this API becomes awkward because of the two
different closure parameters. Neither

```swift
Button(action: {
  ...
  ...
}) {
  Text("Hello!")
}
```

nor

```swift
Button(action: {
  ...
  ...
}, label: {
  Text("Hello!")
})
```

compose that well.

Similar issues show up when writing control-flow-like functionality, such as an API that triggers one of two
actions based on a conditional that will be evaluated asynchronously:

```swift
func when<T>(_ condition: @autoclosure () -> Bool, then: () -> T, `else`: () -> T) -> T {
  ...
}
```

As before, there is no good mix for providing both the `then` and `else` closures.

## Proposed solution

This proposal introduces syntactic sugar for providing multiple, labeled trailing closures, extending the
syntax to cover all of the use cases that are awkward in the language today. A set of curly braces delimits
the block of trailing closures, with each trailing closure indicated by an argument label or an empty label
placeholder `_:` inside.

For example, Ehab's example becomes:

```swift
UIView.animate(withDuration: 0.7, delay: 1.0, options: .curveEaseOut) {
  animations: {
    self.view.layoutIfNeeded()
  }
  completion: { finished in
    print("Basket doors opened!")
  }
}
```

Similar to computed properties, the outer curly braces syntactically hold all of the trailing closures
together. Within those curly braces are argument label-closure pairs to specify the trailing closures,
which makes it clear what the purpose of each closure is. The call site also nicely separates
the "configuration" arguments (how to animate) from the "action" arguments (what to do at each step).
This syntax handles nesting cleanly; consider Anupam's example again, now with multiple trailing
closures:

```swift
func toggle() {
  UIView.animate(withDuration: 1) {
    animations: {
      self.myView.backgroundColor = UIColor.green
      self.myView.frame.size.width += 50
      self.myView.frame.size.height += 20
      self.myView.center.x += 20
    }
    completion: { _ in
      UIView.animate(withDuration: 1, delay: 0.25, options: [.autoreverse, .repeat]) {
        animations: {
          self.myView.frame.origin.y -= 20
        }
      }
    }
  }
}
```

Here, we've eliminated the inconsistencies where some "calls" close with a single `}` and others
with a `})`. The new syntax composes well with SwiftUI's `Button`:

```swift
Button {
  action: {
    ...
    ...
    ...
  }

  label: {
    Text("Hello!")
  }
}
```

and our `when(then:else:)` control-flow construct:

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

Note that none of the APIs used here need to change. This proposal improves
[clarity at the point of use](https://swift.org/documentation/api-design-guidelines/#fundamentals) for
many existing APIs, without requiring the API authors to make changes.

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

Note that the new syntax also allows specifying closures for unnamed parameters by using an “empty” label placeholder `_:` for each, e.g.,

```swift
func foo(_ fn1: () -> Void, _ fn2: () -> Void) {}

foo {
  _: { ... }
  _: { ... }
}
```

Is equivalent to:

```swift
foo({ ... }, { ... })
```

The same applies even when using the proposed syntax for a single trailing closure, which provides a trailing syntax for specifying 
the argument label of a function that accepts a single closure parameter:

```swift
func foo(fn: () -> Void) {
}

foo {
  _: { ... }
}

foo {
  fn: { ... }
}
```

Would be transformed into:

```swift
foo({ ... })

foo(fn: { ... })
```

First call is treated as if being a single trailing closure `foo { ... }`, second call uses new syntax to preserve a label, both calls are accepted.

Since all of the essential source information is preserved (locations of all labels and closure blocks) it would be possible for the type-checker to produce diagnostics for invalid code without any changes.

## Source compatibility

This is an additive proposal, which makes ill-formed syntax well-formed but otherwise does not affect existing code.

## Effect on ABI stability

This feature is implementable entirely in the parser, as a syntactic transformation on call expressions. It, therefore, has no impact on the ABI.

## Effect on API resilience

Proposed changes do not introduce features that would become a part of a public API.

## Alternatives considered

It has been noted that code layout conventions can improve the readability of the existing syntax by placing labeled arguments on separate lines e.g.

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

This isn't much different from the examples in the Motivation section. The mix of `)` and `}` is still jarring to read and surprisingly hard to
write correctly. Note that alternating `)` and `}` in the nested-closures example:

```swift
func toggle() {
  UIView.animate(withDuration: 1, 
    animations: {
      self.myView.backgroundColor = UIColor.green
      self.myView.frame.size.width += 50
      self.myView.frame.size.height += 20
      self.myView.center.x += 20
    },
    completion: { _ in
      UIView.animate(withDuration: 1, delay: 0.25, options: [.autoreverse, .repeat], 
        animations: {
          self.myView.frame.origin.y -= 20
        }
      )
    }
  )
}
```

Another alternative syntax involves multiple trailing closures written more in the style of Swift's if-else, e.g.,

```swift
when(2 < 3) { 
  3 
} else { 
  4 
}
```

This does look more like if-else, so it fits in with that control-flow statement well, but the lack of labels makes it harder
to understand the purpose of the first closure.
This issue becomes much more apparent with the SwiftUI `Button` example:

```swift
Button {
  ...
  ...
  ...
} label {
  Text("Hello!")
}
```

Nothing makes it clear that the first closure is the "action" of the button; one would have to read through the contents of
`...` to discern what it's trying to do. This approach also requires newline sensitivity;
if the "label" were written on a new line, it would be parsed as a separate call to a function named "label":

```swift
Button {
  /* action code */
  ...
  ...
  ...
}
label {   // call to a function named "label", not part of the Button creation
  Text("Hello!")
}
```

There has been some desire to drop the `:` from the syntax as proposed, e.g.,

```swift
Button {
  action {
    ...
    ...
    ...
  }

  label {
    Text("Hello!")
  }
}
```

One immediate technical issue with this syntax is that it is grammatically ambiguous: is this two trailing closures with argument labels
"action" and "label", or is it a single trailing closure calling functions named "action" and "label", each with a trailing
closure? Source compatibility requires the latter interpretation, because this is valid (syntactically) today.

The second issue with this approach is that it doesn't look like the argument labels used elsewhere. This issue is
more apparent with one of the `UIView.animate` examples:

```swift
UIView.animate(withDuration: 0.7, delay: 1.0, options: .curveEaseOut) {
  animations {
    self.view.layoutIfNeeded()
  }
  completion { finished in
    print("Basket doors opened!")
  }
}
```

Three of the argument labels here (`withDuration`, `delay`, and `options`) use a different syntax than the other two
(`animations` and `completion`), making it less clear that all of these are argument labels to the call.
