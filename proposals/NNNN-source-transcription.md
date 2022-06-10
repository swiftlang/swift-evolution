# Transcribed values

* **Radar:** rdar://15581564
* **See Also:** [SE-0293](https://github.com/apple/swift-evolution/blob/main/proposals/0293-extend-property-wrappers-to-function-and-closure-parameters.md#passing-a-projected-value-argument)

## Introduction

Ever need the source code equivalent to an expression, such as in this C example?

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

Wish you could do the same in Swift?

Me too!

## Solution

I propose introducing a new property wrapper with special compiler support named `Transcribed<T>`, such that the expression `@Transcribed T` when used as an argument produces a value that can be converted to its original source code:

```swift
@frozen @propertyWrapper
public struct Transcribed<T> {
  public var wrappedValue: T { get }
  public var projectedValue: Self { get }

  @available(*, deprecated,
              message: "@Transcribed in this position will not produce a "
                       "meaningful transcription at runtime.")
  public init(wrappedValue: T)

  /// Initialize an instance of
  @usableFromInline
  internal init(wrappedValue: T, transcription: String)
  
  @available(*, unavailable,
              message: "@Transcribed should not be applied to another "
                       "transcribed value.")
  public init<U>(wrappedValue: Transcribed<U>)
  where Self == Transcribed<Transcribed<U>>
}
```

### Transcribing a value

To transcribe a value (that is, retrieve the Swift source expression used to compile it), a new `ExpressibleByStringLiteral` initializer is introduced:

```swift
extension String {
  public init<T>(transcribing value: Transcribed<T>)
  
  @available(*, unavailable,
              message: "Cannot transcribe `value`. Did you mean to write "
                       "`String(transcribing: $value)`?")
  public init<T>(transcribing value: T)
}
```

### Example usage

Access to an instance of `@Transcribed T` behaves like any other property wrapper when used in parameter position:

```swift
func myAssert(@Transcribed _ condition: Bool) {
  if !condition {
    let condMsg = String(transcribing: $condition)
    fputs("Assertion failed: \(condMsg)\n", stderr)
    abort()
  }
}

myAssert(1 > 2)
// OUTPUT: Assertion failed: 1 > 2
```

## Implementation details

This proposal is dependent on SE-0293 having been implemented fully and correctly. I've run into a couple of reproducible compiler crashes and will ping relevant folks for assistance.

### Compiler changes

In addition to the new API proposed above, we will need to give the compiler special knowledge of this type such that when `@Transcribed` appears as an attribute on a function argument, the compiler knows to synthesize a call to an internal `init(wrappedValue:transcription:)` initializer instead of `init(wrappedValue:)`. The compiler should have enough contextual information to pass, as the second argument, a `StringLiteralExpr` equal to the caller-side source code of the first argument:

```swift
func sourceCode<T>(@Transcribed of value: T) -> String {
  return String(transcribing: $value)
}
let x = sourceCode(of: 1 + 1)

// SYNTHESIZED AS:
let t = Transcribed<Int>(wrappedValue: 2, transcription: "1 + 1")
let x = sourceCode(of: t)
```

### Compiler non-changes

Any other uses of `@Transcribed` would *not* be special-cased by the compiler, leading to a warning being emitted as described in the Swift snippet above:

```swift
struct S {
  @Transcribed var x: Int = 12345
  // WARNING: @Transcribed in this position will not produce a meaningful transcription at runtime.
  
  func printX() {
    print(String(transcribing: $x))
    // OUTPUT: 12345 (initial value of `x`)
  }
}
```

### Transcribing the wrong thing

If the developer writes `String(transcribing: x)` by mistake instead of `String(transcribing: $x)`, they'll get this error (ideally with a fix-it):

```swift
func printSourceCode<T>(@Transcribed of x: T) {
  print(String(transcribing: x))
  // ERROR: Cannot transcribe `value`. Did you mean to write `String(transcribing: $value)`?
}
```

A stretch goal could be to have the compiler synthesize a read of `$x` instead of `x` in this scenario. That would be inconsistent with other property wrappers' behaviour, so discussion is warranted.

## Back-deployment

All the proposed API can be inlined, so the entire rigamarole could be backported as far back as the introduction of argument-position property wrappers (i.e. Swift 5.5.)