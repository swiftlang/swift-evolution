# Source transcription

* Proposal: [SE-NNNN](NNNN-source-transcription.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift#59346](https://github.com/apple/swift/pull/59346)

## Introduction

Through the use of macros, C has the ability to capture the source of an expression for use in diagnostics, for instance in the standard `assert()` macro. Swift on the other hand does not have a preprocessor or macros. As a result, assertions, unit testing frameworks, and other diagnostic tools produce less-than-optimal output. This change introduces a mechanism for capturing the source code of an expression into a string literal at compile time.

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

This loss of information is particularly vexing when testing is performed during continuous integration where immediate access to the failed test is not possible. For example, if a unit test fails in Xcode Cloud, Jenkins, etc., often the only diagnostic information available is what was logged by XCTest. A message that simply states `"Assertion failed"` is much less helpful in these circumstances than one that states `"Assertion failed: 1 > 2"`.

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

_transcription-literal_ → #transcription **( of :** local-parameter-name **)**<br>

And _default-argument-clause_ is redefined to:

_default-argument-expression_ →  expression | transcription-literal<br>
_default-argument-clause_ → **=** default-argument-expression

Note that _literal-expression_ is _not_ redefined because `#transcription(of:)` is only valid in default-argument position. Other magic literal expressions (such as `#line` or `#filePath`) can be used in any position where a literal expression would be valid, but `#transcription(of:)` can only produce a useful string literal when it is a default argument since it needs both the local name of an argument to the same function _and_ visibility into the caller at compile-time.

### In practice

That's the formal change. In terms of source code, a developer can now specify `#transcription(of: x)` as a default argument, where `x` is the name of another argument to the same function. At compile-time, the expression represented by `x` _at the callsite_ is converted into a string literal. For example:

```swift
func f(_ x: Int, _ y: String = #transcription(of: x)) {
  ...
}
f(1 + 2 + 3)
```

When the call `f(1 + 2 + 3)` is compiled, the compiler "sees" the expression `#transcription(of: x)` and looks up the source representation of the argument `x` (in this case, `"1 + 2 + 3"`), converts it to a string literal, and passes it as the default value for the argument `y`.

### Edge cases

* There is no need to specify the transcription after the argument it transcribes. That is, an argument and its transcription can appear in any order in a function's argument list.

* The transcription of a transcription literal for argument `x` is `#transcription(of: x)`. That is, in the following function declaration:

    ```swift
    func f(_ x: Int, _ y: String = #transcription(of: x), _ z: String = #transcription(of: y)) {
    }
    ```

    The value of `z` will equal `#transcription(of: x)`.

## Source compatibility

This change is additive.

## Effect on ABI stability

This change does not affect a module's ABI.

## Effect on API resilience

Swift modules would start to include `#transcription(of:)` which could prevent their use with old compilers. The result of this expression, as a string literal, is compiled directly into the caller of any function that uses it, so there are no binary compatibility or backporting considerations.

The addition of this feature does not affect any existing compiled code: if a function is updated to use `#transcription(of:)` as a default argument value, callers compiled beforehand are not affected.

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

    If a developer decides they want to implement a property wrapper for this functionality, they can do so by using `#transcription(of:)` themselves.

* We considered various other names for the magic identifier literal, including `#source(of:)`, `#sourceCode(of:)`, `#transcription(ofArgumentNamed:)`, and so forth. We picked `#transcription(of:)` because "transcription" is not otherwise an overloaded term in Swift or its compiler, but the jury is still out. Suggestions are welcome here.

* We considered having developers specify arguments by index instead of by name and calling the magic identifier literal `#transcription(ofArgumentAtIndex:)`. The implementation would be much simpler, to be sure, but variadic arguments get in the way:

    ```swift
    func f(_ x: Int..., _ y: Int, transcriptionOfY: String = #transcription(ofArgumentAtIndex: ???))
    ```
    
    What is the index of `y`? Is it 1 (zero-based)? 2 (one-based)? Is it arity-of-`x`-plus-one (each variadic argument has its own index on the caller's side)?
    
* We considered allowing the use of the magic identifier literal outside of a default argument. It is not possible to do so in a way that lets developers capture useful source transcriptions since the expression would end up being evaluated on the callee side, not the caller side. If passed an argument's local name such as `x`, the string literal would simply equal `"x"`; if passed some other expression such as `x / 1`, it would correctly represent the expression—but a developer could just as easily write out `"x / 1"` themselves.

## Future Directions

There are a few functions in the Swift standard library that could benefit from source code transcription. For example, `assert()` is currently declared in the Swift standard library like so:

```swift
public func assert(
  _ condition: @autoclosure () -> Bool,
  _ message: @autoclosure () -> String = String(),
  file: StaticString = #file, line: UInt = #line
)
```

With the addition of `#transcription(of:)`, we could redefine it:

```swift
public func assert(
  _ condition: @autoclosure () -> Bool,
  _ message: @autoclosure () -> String = #transcription(of: condition),
  file: StaticString = #file, line: UInt = #line
)
```

Then, when an assertion fails, the expression that failed could be captured in the crash message emitted before the process terminates.

## Acknowledgments

Thanks much to Holly Borla and Joe Groff for their technical assistance, as well as Brian Croom and Stuart Montgomery for prodding me into working on this pitch.