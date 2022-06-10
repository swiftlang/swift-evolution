# Source transcription

* Proposal: [SE-NNNN](NNNN-source-transcription.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift#59346](https://github.com/apple/swift/pull/59346)
* Bugs: [rdar://15581564](rdar://15581564)

## Introduction

Through the use of macros, C has the ability to capture the source of an expression for use in diagnostics, for instance in the standard `assert()` macro. Swift doesn't have the ability to do so. As a result, assertions, unit testing frameworks, and other diagnostic tools produce less-than-optimal output. This change introduces a mechanism for capturing the source code of an expression into a string literal at compile time.

## Motivation

Consider the following C function and macro:

```c
void my_assert_impl(
  bool condition,
  const char *cond_msg
) {
  if (!condition) {
    fprintf(stderr, "Assertion failed: %s\n", cond_msg);
    abort();
  }
}
#define my_assert(CONDITION) my_assert_impl((CONDITION), #CONDITION)

my_assert(1 > 2);
// OUTPUT: Assertion failed: 1 > 2
```

A user who wants to assert a condition is `true` would call `my_assert(theCondition)`. If `theCondition` is `false`, a string representation of it is printed to the standard error stream and the program is terminated. This is a useful tool for diagnosing issues and is widely used throughout the industry.

Swift's `assert()`, on the other hand, is not able to capture a source code representation of its `condition` argument: if an assertion fails, that information is lost.

The same issue affects unit testing frameworks like XCTest: when implemented in C, C++, or Objective-C, they are able to capture a source code representation of arguments to e.g. `XCTAssertTrue()`. When implemented in Swift, that information is lost and the diagnostic messages produced by the framework are of lower quality.

## Proposed solution

I propose introducing a new magic identifier literal, `#transcription(of:)`. This new magic identifier literal, unlike existing ones, takes an argument, i.e. the name of another argument to the current function. It can then be used as a default argument to a function. When used in that position, it resolves to the source code representation of the argument it names. For example:

```swift
func f(_ x: Int, transcriptionOfX: String = #transcription(of: x)) {
  print(x)
  print(transcriptionOfX)
}
f(1 + 2 + 3)
// OUTPUT: "6"
// OUTPUT: "1 + 2 + 3"
```


## Detailed design

### Formal grammar

We will add the following to the language's formal grammar:

_transcription-literal-pattern_ → expression | local-parameter-name<br>
_transcription-literal_ → #transcription **( of :** transcription-literal-pattern **)**<br>

We amend the definition of _literal-expression_ to include:

_literal-expression_ → _transcription-literal_</br>

And _default-argument-clause_ is redefined to:

_default-argument-expression_ →  expression | transcription-literal<br>
_default-argument-clause_ → **=** default-argument-expression

### In practice

That's the formal change. In terms of source code, a developer can now specify `#transcription(of: x)` as a default argument, where `x` is the name of another argument to the same function. Today, `assert()` in Swift is declared as:

```swift
public func assert(
  _ condition: @autoclosure () -> Bool,
  _ message: @autoclosure () -> String = String(),
  file: StaticString = #file, line: UInt = #line
)
```

We can now redefine it in terms of `#transcription(of:)`:

```swift
public func assert(
  _ condition: @autoclosure () -> Bool,
  _ message: @autoclosure () -> String = #transcription(of: condition),
  file: StaticString = #file, line: UInt = #line
)
```

Grammatically speaking, it is also possible to use `#transcription(of:)` in the body of a function or in any other context where a string literal would be valid. However, the context necessary to capture the actual argument's source is only available in the caller, so a sub-optimal string will be produced:

```swift
func f(_ x: Int) {
  print(#transcription(of: 1 + x)) // OUTPUT: "1 + x"
  print(#transcription(of: x)) // OUTPUT: "x"
}
```

We'll warn developers if `#transcription(of:)` is used in a way that may produce an unexpected result, as above.

## Source compatibility

This change is additive.

## Effect on ABI stability

This change does not affect a module's ABI.

## Effect on API resilience

Swift modules would start to include `#transcription(of:)` which could prevent their use with old compilers. The result of this expression, as a string literal, is compiled directly into the caller of any function that uses it, so there are no binary compatibility or backporting considerations.

## Alternatives considered

We considered several alternatives:

* Most visibly, we considered exposing this functionality as a property wrapper and `String` initializer instead of a magic identifier, _à la_:
    
    ```swift
    func f(@Transcribed _ x: Int) {
      print(x)
      print(String(transcribing: $x))
    }
    ```
    
    The use of a property wrapper had some aesthetically pleasing qualities, but it came with a number of downsides:
    * We would need to introduce a new type to the standard library, `Transcribed<T>`, as well as a new initializer on `String`. Introducing new members to the standard library comes with a backwards-compatibility cost.
    * We would need to teach the compiler about the special behaviour of this new type, which is unlike that of any other property wrapper.
    * To extract the transcription of `x` above, you must use the "dollar syntax" to get at the property wrapper's projected value instead of its wrapped value.
    * We would need to add special handling for this property wrapper so that its value would be computed on the caller's side rather than the callee's side without _also_ having to use "dollar syntax" at the call site.

* We considered having developers with a need for this functionality add their own compiler passes. Needless to say, this approach doesn't scale well and it doesn't solve for `assert()`.

* We considered various other names for the magic identifier literal, including `#source(of:)`, `#sourceCode(of:)`, `#transcription(ofArgumentNamed:)`, and so forth. We picked `#transcription(of:)` because "transcription" is not otherwise an overloaded term in Swift or its compiler, but the jury is still out. Suggestions are welcome here.

* We considered having developers specify arguments by index instead of by name and calling the magic identifier literal `#transcription(ofArgumentAtIndex:)`. The implementation would be much simpler, to be sure, but variadic arguments get in the way:

    ```swift
    func f(_ x: Int..., _ y: Int, transcriptionOfY: String = #transcription(ofArgumentAtIndex: ???))
    ```
    
    What is the index of `y`? Is it 1 (zero-based)? 2 (one-based)? Is it arity-of-`x`-plus-one (each variadic argument has its own index on the caller's side)?
    
* We considered forbidding the use of the magic identifier literal outside of a default argument. Feedback on this alternative would be valuable.

## Acknowledgments

Thanks much to Holly Borla and Joe Groff for their technical assistance, as well as Brian Croom and Stuart Montgomery for prodding me into working on this pitch.