# Support use of an optional label for the first trailing closure

* Proposal: [SE-NNNN](NNNN-optional-label-for-first-trailing-closure.md)
* Authors: [Xiaodi Wu](https://github.com/xwu)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#31666](https://github.com/apple/swift/pull/31666)

<!--
*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

This proposal extends trailing closure syntax by supporting the use of an
__optional__ argument label for the first trailing closure. When paired with
changes in tooling behavior, this feature would promote the alignment of
declaration and use sites without source-breaking changes.

<!--
Swift-Evolution thread: [TBD](https://forums.swift.org/)
-->

## Motivation

__Closure expressions__ in Swift have a lightweight syntax with several
"optimizations" as described in _The Swift Programming Language_:

> * Inferring parameter and return value types from context
> * Implicit returns from single-expression closures
> * Shorthand argument names
> * Trailing closure syntax

These optimizations allow users to write out only the most salient details
explicitly at the point of use, promoting clarity when used judiciously. A
caller can take advantage of some or all of these optimizations in a variety
of combinations. For instance, one may use trailing closure syntax while
explicitly naming the return type.

<!--
Take, for instance, the different ways of calling the following function:

```swift
func frobnicate(by: (String) -> Bool) { /* ... */ }

frobnicate(by: { (value: String) -> Bool in
  return value == "Hello"
})

// Inferring parameter type:
frobnicate(by: { (value) -> Bool in
  return value == "Hello"
})
frobnicate(by: { value -> Bool in
  return value == "Hello"
})

// Inferring return type:
frobnicate(by: { value in
  return value == "Hello"
})

// Implicit return from single-expression closure
// (now available for all functions):
frobnicate(by: { value in
  value == "Hello"
})

// Shorthand argument name:
frobnicate(by: { $0 == "Hello" })

// Trailing closure syntax:
frobnicate() { $0 == "Hello" }
frobnicate   { $0 == "Hello" }
```

These optimizations do not have to be used in only the progression outlined
above. For instance, one may use trailing closure syntax while explicitly naming
the return type.
-->

In Swift, function arguments can have labels prescribed by the author of the
function that clarify the role of that argument. For instance, the mathematical
function known as `atan2` in C/C++ is named `atan2(y:x:)` in Swift so as to
emphasize the somewhat unintuitive order in which arguments must be passed to
that function. However, in the case of trailing closure syntax, the first
trailing closure is __always__ written without any argument label. For example:

```swift
// Without trailing closure syntax:
[1, 2, 3].first(where: { $0 > 2 })

// With trailing closure syntax:
[1, 2, 3].first { $0 > 2 }
```

This syntax presents at least three significant limitations which have been
present in every shipping version of Swift, which we'll explore in turn. In
each of these cases, the present workaround is _to abandon the use of trailing
closure syntax_. Indeed, the authors of [Google's style guide][ref 0] describe
almost exactly the same limitations and prohibit the use of trailing closure
syntax under those circumstances. Unfortunately, users cannot then avail
themselves of all the other benefits of trailing closure syntax (such as
decreased nesting) which may be just as applicable to those use sites as they
are elsewhere.

[ref 0]: https://google.github.io/swift/#trailing-closures

### Exclusion from statement conditions

At present, the use of trailing closure syntax is excluded from `if` conditions
and similar scenarios. This is sometimes diagnosed as a warning when the usage
is merely confusable to humans but simple enough for the parser; in more complex
scenarios, it is an outright parsing error:

```swift
if let x = [1, 2, 3].first { $0 > 2 } {
  print(x)
}
// Warning: Trailing closure in this context is confusable...
// Fix-it: Replace ' { $0 > 2 }' with '(where: { $0 > 2 })'

if let x = [1, 2, 3].first {
  $0 > 2
} {
  print(x)
}
// Error: Closure expression is unused
// Error: Consecutive statements on a line must be separated by ';'
// Error: Top-level statement cannot begin with a closure expression
```

In this case, there is one workaround for the user which does not require
abandoning trailing closure syntax. Namely, the entire caller can be surrounded
by parentheses instead:

```swift
if let x = ([1, 2, 3].first {
  $0 > 2
}) {
  print(x)
} // Prints "3"
```

### Inability to disambiguate the intended matching parameter

Swift uses a "backwards scan" through function parameters to match an unlabeled
trailing closure to a compatible parameter:

```swift
func frobnicate(a: () -> Int = { 42 }, b: (() -> Int)? = nil) {
  if let b = b {
    print(a(), b())
  } else {
    print(a(), "nil")
  }
}

frobnicate { 21 }     // Prints "42 21", equivalent to...
frobnicate(b: { 21 }) // Prints "42 21"
```

A user must abandon trailing closure syntax in order to specify that the given
closure expression is intended to match the parameter labeled `a`:

```swift
frobnicate(a: { 21 }) // Prints "21 nil"
```

If the author of `frobnicate` revises the function to take an additional
parameter of optional function type, the behavior of `frobnicate { 21 }` will
change:

```swift
func frobnicate(a: () -> Int = { 42 }, b: (() -> Int)? = nil, c: Any? = nil) {
  if let b = b {
    print(a(), b())
  } else {
    print(a(), "nil")
  }
}

frobnicate(b: { 21 }) // Still prints "42 21", no longer equivalent to...
frobnicate { 21 }     // Now prints "42 nil"
```

> This is not to suggest that APIs of the sort above are ideally designed.
> However, the language itself should, whenever possible, help API consumers
> write correct code even if API authors sometimes make questionable design
> choices.

A related limitation is the inability to disambiguate among two overloads which
differ only by argument label if trailing closure syntax is used:

```swift
func frobnicate(ifSuccess: () -> Result<String, Error>) { /* ... */ }
func frobnicate(ifFailure: () -> Result<String, Error>) { /* ... */ }

frobnicate { .success("Hello, World!") }
// Error: Ambiguous use of 'frobnicate'
// Fix-it: Use an explicit argument label instead of a trailing closure to call
//   'frobnicate(ifSuccess:)'
// Fix-it: Use an explicit argument label instead of a trailing closure to call
//   'frobnicate(ifFailure:)'
```

### Loss of meaningful words at the use site

Certain APIs have not been ideally designed for use with trailing closure
syntax. In the standard library, for example, `drop(while:)` reads like a
different function without its argument label:

```swift
let x = [1, 2, 3, 2, 1].drop { $0 < 2 }
print(x) // Prints "[2, 3, 2, 1]"
```

When there is only a single parameter, it can be straightforward for an API
author to adapt to this limitation of trailing closure syntax by agglomerating
the otherwise dropped words to the base name. Indeed, the API naming guidelines
are now [amended][ref 10] to suggest that authors take the issue into account
for the first trailing closure.

[ref 10]: https://forums.swift.org/t/accepted-se-0279-multiple-trailing-closures/36141

However, making that same change would be more difficult in the case of APIs
where the parameter in question is the last of several: there could be no
straightforward base name that can satisfactorily substitute for an aptly
labeled argument towards the end of the use site.

Moreover, when multiple parameters at the end of a parameter list are of
function type, _any_ of these could have its label dropped at the use site,
since users may choose not to use trailing closure syntax for an arbitrary
number of arguments (in order to preserve meaningful words, for example):

```swift
func frobnicate(_: [Int], excluding: (Int) -> Bool, transform: (Int) -> Int) {
  /* ... */
}

frobnicate([1, 2, 3, 2, 1].drop { $0 < 2 })
  { $0 < 2 } // We certainly don't want to leave this argument unlabeled!
  transform: { $0 * 2 }

frobnicate([1, 2, 3, 2, 1].drop { $0 < 2 }, excluding: { $0 < 2 })
  { $0 * 2 }

// So what can we accomplish merely changing the base name?
let frobnicateAfterExcludingByTransforming = frobnicate // 🤨
```

Addressing this issue at the level of API design could require more disruptive
changes, such as altering the order of arguments. This is a nontrivial ask of
API authors to work around a deficiency in the language itself. Therefore, this
proposal aims to provide a solution to address the problem at its root.

## Proposed solution

This proposal would extend trailing closure syntax by supporting the use of an
__optional__ argument label for the first trailing closure.

(As with subsequent trailing closures, the user can write `_` to indicate that
the trailing closure should match an unlabeled parameter, but the need for such
an explicit spelling should be rare.)

This solution allows Swift users to address each of the limitations enumerated
above without abandoning trailing closure syntax:

* Users can move existing callers into statement conditions without creating any
  parsing ambiguities:

  ```swift
  x = [1, 2, 3].first where: { $0 > 2 }
  if let x = x {
    /* ... */
  }

  if let x = [1, 2, 3].first where: { $0 > 2 } {
    /* ... */
  }
  ```

* In the setting of a frequently evolving API, or where the "backwards scan"
  rule may lead to an unintuitive result, users can specify explicitly which
  parameter should match the trailing closure:

  ```swift
  func frobnicate(a: () -> Int = { 42 }, b: (() -> Int)? = nil) { /* ... */ }
  frobnicate b: { 21 }
  ```

* Where the label provides meaningful information, users can preserve that
  information for the reader even when API authors have not reworked their APIs
  (or cannot do so) specifically for trailing closures:

  ```swift
  let x = [1, 2, 3, 2, 1].drop while: { $0 < 2 }

  frobnicate(x)
    excluding: { $0 < 2 }
    transform: { $0 * 2 }
  ```

* Finally, in cases where multiple trailing closures are involved and one
  closure is not clearly "more primary," users can apply their judgment to
  label all trailing closure expressions:

  ```swift
  Binding
    get: { /* ... */ }
    set: { /* ... */ }
  
  store.scope
    state:  { $0.login }
    action: { AppAction.login($0) }
  // See: https://github.com/pointfreeco/swift-composable-architecture/

  viewStore.binding
    get:  { $0.name } 
    send: { Action.nameChanged($0) }
  // See: https://github.com/pointfreeco/swift-composable-architecture/

  let isSuccess = result.fold
    success: { _ in true }
    failure: { _ in false }
  ```

By making the use of a label __optional__ for the first trailing closure, source
compatibility is maintained with all existing code.

### Objections

One possible objection to the syntax proposed is that users are unused to
function names juxtaposed with argument labels without the use of parentheses.
Indeed, [SE-0279][ref 20] claims: "Many find this spelling unsettling."

[ref 20]: https://github.com/apple/swift-evolution/blob/master/proposals/0279-multiple-trailing-closures.md

Certainly, this generalization will lead superficially to a new appearance for
callers such `drop while: { ... }` because of the lack of punctuation between
the base name and argument label.

It is important to emphasize, however, that the option to omit parentheses is a
widely-adopted _existing_ feature of trailing closure syntax. Users have always
had the choice of using parentheses to create a more familiar appearance:
`drop() { ... }`. They would continue to have that choice with the adoption of
this proposal, even when the trailing closure is labeled.

Meanwhile, the use of argument labels outside of parentheses for trailing
closures is also an existing feature adopted in SE-0279. There can be nothing
intrinsic to labeling the _first_ trailing closure which would be more
unsettling than labeling the _second_ trailing closure using the same syntax
and rules.

Finally, it is worth recalling that separation of two identifiers only by
whitespace already occurs in Swift, when function declarations use internal
parameter names that differ from argument labels:
`func f(argumentLabel parameterName: Int)`.

Therefore, we are not innovating in this area by supporting an optional label
for the first trailing closure. Had we attempted some new design, it would be
difficult to rule out the possibility that deficiencies inherent to that
design might account for any feeling that the result is unsettling, thereby
raising the possibility that such a perception might persist so long as the
design remains unaltered. In this case, however, we can have confidence that
any initial uneasiness with the superficially unfamiliar appearance of
`drop while: { ... }` will dissipate with experience.

Another possible objection to the syntax proposed is that it will lead to a
proliferation of different styles among users, leading to inconsistency and a
corresponding proliferation of dicta among linters and style guides.

There are several reasons not to fear such an outcome:

First, as recounted above, closure expressions already offer a number of
"optimizations" to users, who can choose to include or omit various information
for the sake of clarity at the use site. Experience shows that users have used
these optimizations generally to good rather than ill effect. This proposal
demonstrates a number of scenarios where this additional feature—which we could
consider another syntax "optimization"—could similarly be used to good effect.

Second, where linters and style guides have recommended against the use of
trailing closures, it has often been for lack of clarity at the use site. For
example, Google's style guide prohibits their use when a function call has
multiple closure arguments so that each can be labeled. In other words, best
practices have _not_ coalesced towards blanket requirements to use or not to use
some syntactic form, but rather to recommend use in cases where the resulting
code is clear and non-use in cases where the result is unclear. Providing the
opportunity for labels to be used for all trailing closures would obviate many
current style guide recommendations against the use of trailing closures.

Third, although what's proposed here is an __optional__ feature, consistency
can be obtained (and users can be spared any indecision) by consistent
first-party tooling behavior, which will permit alignment of declaration and
use sites without source-breaking changes.

### Tooling behavior

Swift's first-party code completion and formatting tools can make use of the
feature proposed here to drive alignment of declaration and use sites without
additional syntax or source-breaking changes.

When a set of behaviors is adopted consistently across Swift's first-party
tools, API authors gain the ability to reason about readability at the use site,
and API consumers are unburdened from having to make style choices (while still
retaining the ability to improve the clarity of use sites without waiting on API
authors—_should they so choose_).

<details>
<summary>(Click to expand or collapse this subsection.)<br>
For <b>illustrative</b> purposes, one possible set of behaviors that would
accomplish that objective is outlined.</summary>

1. Where there is only one possible trailing closure, prefer an unlabeled
   closure if the parameter itself is unlabeled:

   ```swift
   // Preferred:
   let sum = measurements.reduce(0) { $0 + $1 }

   // Not preferred:
   let sum = measurements.reduce(0) _: { $0 + $1 }
   ```

2. Where there is only one possible trailing closure, prefer a labeled closure
   if the parameter itself is labeled:

   ```swift
   // Preferred:
   words.sort by: { $0 > $1 }
   let x = numbers.drop while: { $0 < 2 }

   // Not preferred:
   words.sort { $0 > $1 }
   let x = numbers.drop { $0 < 2 }
   ```

   This might be controversial because it would diverge from currently written
   code (although that code would still remain valid). The intention is to work
   in conjunction with (1) to align declaration sites with use sites, giving API
   authors control over which arguments are labeled by default (albeit not
   mandatorily enforced by the compiler). Where the API _consumer_ deems the
   result to be verbose and unhelpful, they can delete the label.

   (One alternative here is to adopt a heuristic, at least for methods known to
   the compiler. In [SE-0118][ref 40], a great number of parameter labels for
   closures were reworked, with many standardized to `by` when another word or
   phrase was not more apt. Therefore, we could treat parameters labeled `by` as
   though they were unlabeled—not the most elegant of long-term rules, however.)

3. Where there are multiple possible trailing closures and _at least_ one of
   the parameters is unlabeled, deem the _last_ such parameter to be primary;
   prefer writing the call site such that the corresponding argument is the
   first and unlabeled trailing closure:

   ```swift
   func when<T>(
     _ condition: @autoclosure () -> Bool,
     _ then: () -> T,
     `else`: () -> T
   ) -> T { /* ... */ }

   // Preferred:
   when(2 < 3) {
     print("then")
   } else: {
     print("else")
   }

   // Not preferred:
   when(2 < 3)
     _: { print("then") }
     else: { print("else") }
   ```

4. When there are multiple possible trailing closures, and none of the
   parameters are unlabeled, deem them to be equal in importance until such
   time as the API author reworks those labels; prefer writing the call site
   such that all of the corresponding arguments are trailing and labeled:

   ```swift
   // Preferred:
   Binding
     get: { ... }
     set: { ... }
   
   ipAddressPublisher.sink
     receiveCompletion: { ... }
     receiveValue: { ... }
   
   // Not preferred:
   Binding {
     ...
   } set: {
     ...
   }

   ipAddressPublisher.sink {
     ...
   } receiveValue: {
     ...
   }
   ```

5. In the setting of statement conditions, where (1) and (3) aren't possible,
   prefer surrounding the entire caller with parentheses over abandoning
   trailing closure syntax.

[ref 40]: https://github.com/apple/swift-evolution/blob/master/proposals/0118-closure-parameter-names-and-labels.md
</details>

## Detailed design

This proposal would modify the grammar, as already modified in SE-0279, by
making the unlabeled `expr-closure` optional that precedes the remaining labeled
trailing closures `(identifier|keyword|'_') ':' expr-closure`.

The grammar would be relaxed to allow the use of all-labeled trailing closures
in the setting of statement conditions. The treatment of unlabeled trailing
closures in that setting would remain unchanged.

The same rule regarding resolution of unescaped `default:` in favor of the
keyword which currently applies to labeled trailing closures would be maintained
and thereby also apply to a labeled first trailing closure.

The "backwards scan" rule for matching unlabeled trailing closures, as extended
by SE-0279, would also be maintained. That is, a backwards scan through the
parameters to bind all labeled trailing closures to parameters by matching
labels would be performed. Then, if there is an unlabeled trailing closure, the
same scan as has long been done for an unlabeled trailing closure would still be
performed, starting from the last labeled parameter that was matched.

## Source compatibility

This feature will be a purely additive change to the language and introduce no
new grammatical ambiguities.

## Effect on ABI stability

This feature will not have any effect on ABI stability.

## Effect on API resilience

This feature will not have any effect on API resilience.

## Future directions

_A migration story_

As the core team has said, trailing closures stand out as one of the few places
where Swift allows the API consumer to decide whether or not to use a label. In
general, these labels are regarded as part of the name of an API.

With the conviction that matching declaration and use sites by supporting
labeled first trailing closures is the correct course of action, it would be
tempting also to propose that the compiler should warn _against_ label elision.
From a technical perspective, diagnosing this usage would require trivial
effort. A fix-it and a migration tool could lift all current usages seamlessly
into a brave new world.

However, it would be prudent to approach the evolution of the language with a
certain degree of humility afforded by a stepwise approach. Should our
convictions be borne out by experience after implementation of this proposal,
accompanied by adequate tooling, then API authors and consumers will naturally
coalesce around a set of best practices and styles.

When API authors and consumers alike have had adequate time to adapt their code
as a result of this proposal, then it becomes possible to consider one of two
courses of action:

* If, even after APIs have been reworked to account for this proposal, _some_
  still benefit from giving callers the flexibility to elide the label for the
  first trailing closure, while others benefit from use sites that always match
  their declarations, then we may wish to create an attribute to distinguish
  these two groups of APIs.
  
  To choose a deliberately unsuitable name in the vein of
  `@warn_unqualified_access`, we might call this `@warn_elided_trailing_label`.
  If a more stringent approach is preferred, the compiler may even emit an error
  instead of a warning when the attribute is used.

* If, ultimately, all or almost all APIs benefit from use sites that match their
  declarations, then we may move forward with an approach that diagnoses any
  instance of label elision (which does not include cases where the parameter is
  unlabeled, of course) with a warning and a fix-it.

* If, ultimately, all or almost all APIs benefit from giving callers the
  flexibility to elide the label for the first trailing closure, then we would
  not need to take further action.

## Alternatives considered

### Removal of caller discretion in usage of labels

At Swift's present stage of evolution, a change that would only allow unlabeled
trailing closures to match unlabeled parameters would be source-breaking for a
very large number of existing use cases.

One might argue that labels could be made mandatory only in the case of multiple
trailing closures. The rationale might be that, where there is more than one,
there should be clarity as to "which one's what" in a way that's not necessary
for single trailing closures.

However, even single trailing closures can need such clarification when there
are multiple possible _parameters_ that can match. Establishing a mandatory
labeling rule only for multiple trailing closures would cause a divergence that
is not self-evidently justifiable. Moreover, after multiple trailing closures
are shipped as implemented for SE-0279, this too would be a source-breaking
change.

Finally, even in that limited form, a mandatory rule would _require_ the use of
repetitive or unhelpful labels for "primary" trailing closures where API authors
haven't yet reworked them, whereas this proposal would allow API consumers to
delete those labels.

Instead, this proposal stakes out a claim that much of the _benefit_ that can be
gained from such a breaking change would be recovered in a source-compatible way
by adopting this proposal and a consistent behavior throughout first-party (and,
in the future, third-party) tools that _default_ to omitting labels only for
trailing closures that match unlabeled parameters. With time, label elision
would cease to be the go-to option but rather a legacy feature supported for
source compatibility reasons.

As detailed above (see "Future directions"), this proposal leaves room for
future steps that would approach the same end result at a later stage of Swift's
evolution. It should also be noted that there is precedent for code that's
forbidden by Swift's grammar compiling anyway with a warning, as demonstrated
above in the case of trailing closures used in statement conditions. It would be
_possible_, thus, to deprecate label elision without actually breaking any
existing source code by sticking to warnings instead of errors.

### Typechecking changes

As the "backwards scan" rule can produce unintuitive results for matching
unlabeled trailing closures to parameters, a source-breaking change in a future
version of Swift could address the issue, making the results more intuitive.
This would remain a possible avenue of exploration in the future, but it does
not interfere with, nor preclude, the use of labeled trailing closures at the
present time either to disambiguate for the compiler or to clarify for the human
reader.

Indeed, the use of labeled trailing closures would minimize the extent of any
deleterious effects of a source-breaking change to the typechecker that improves
parameter matching for unlabeled trailing closures.

## Acknowledgments

Matthew Johnson for close reading and suggestions.
