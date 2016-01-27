# Either

* Proposal: [SE-0015](https://github.com/apple/swift-evolution/blob/master/proposals/0015-either.md)
* Author(s): [TypeLift](https://github.com/TypeLift)
* Status: **Review**
* Review manager: TBD

## Introduction

This proposal details the addition of a left-biased sum type to the
Swift Standard Library.  Earlier attempts at adding this have been too
specifically focused on error handling (duplicating functionality
`throws` already provides), whereas this implementation will focus on
data, organization, and type safety.  We believe that adding the type
to the standard library and simultaneously emphasizing its broader use cases, 
that is, when you need a type that represents exactly 2 disjoint possibilities,
can dispel the confusion caused in other languages
and quell the conflict with `throws`.

## Motivation

Inevitably, it seems languages reach the point where they see the need
to handle finite-argument disjoint variants with a data type as was
done in C++, C#, D, F#, SML, Haskell, Scala, ALGOL, and many others.
When coupled with a strong, static type system they can be made even
more useful because support for totality checking and safety come from
the language itself.

As before, unlike `throws`, a disjoint union type can be applied in arbitrary
positions, used as a member, and easily checked for completeness
at compile time.  In addition, the lack of a standard union type has
led the Swift community to create [numerous](https://github.com/search?utf8=✓&q=Either+language%3Aswift) 
[duplicate](https://github.com/search?utf8=✓&q=Result+language%3Aswift) implementations of the
same mutually incompatible types over and over and over again.  In the
interest of promoting a type that has received clear interest by the
community, the addition to the Standard Library is necessary.

## Proposed solution

The Swift Standard Library will be updated to include a left-biased
sum type we have called `Either` - though other names may be
appropriate depending on how the type is implemented.

## Detailed design

A complete implementation, based on the [Swiftx](https://github.com/typelift/Swiftx/blob/master/Swiftx/Either.swift) library's implementation, with comments is given below:

```swift
/// The `Either` type represents values with two possibilities:
/// `.Left(LeftValue)` or `.Right(RightValue)`.
///
/// The `Either` type is left-biased by convention.  That is, the values in the
/// `Left` half of the `Either` are considered fair game to be transformed using
/// e.g. `map` and `flatMap` while values in the `Right` half of the `Either`
/// are considered constant.
public enum Either<LeftValue, RightValue> {
	case Left(LeftValue)
	case Right(RightValue)

	/// Much like the ?? operator for `Optional` types, takes a value and a
	/// function, and if the receiver is `.Right`, returns the value, otherwise
	/// maps the function over the value in `.Left` and returns that value.
	public func fold<U>(value: U, @noescape f: (LeftValue) throws -> U) rethrows -> U {
		return try self.either(onLeft: f, onRight: { _ in value });
	}

	/// Applies the given function to any left values contained in the receiver,
	/// leaving any right values untouched.
	public func map<U>(@noescape f: (LeftValue) throws -> U) rethrows -> Either<U, RightValue> {
		switch self {
		case let .Left(l):
			return .Left(try f(l))
		case let .Right(r):
			return .Right(r)
		}
	}

	/// If the `Either` is `Right`, simply returns a new `Right` with
	/// the value of the receiver. If `Left`, applies the function `f`
	/// and returns the result.
	public func flatMap<U>(@noescape f: (LeftValue) throws -> Either<U, RightValue>) rethrows -> Either<U, RightValue> {
		switch self {
		case let .Left(l):
			return try f(l)
		case let .Right(r):
			return .Right(r)
		}
	}

	/// Case analysis for the `Either` type.
	///
	/// If the value is `.Left(a)`, apply the first function to `a`. If it is
	/// `.Right(b)`, apply the second function to `b`.
	public func either<U>(@noescape onLeft onLeft: (LeftValue) throws -> U, @noescape onRight: (RightValue) throws -> U) rethrows -> U {
		switch self {
		case let .Left(e):
			return try onLeft(e)
		case let .Right(e):
			return try onRight(e)
		}
	}

	/// Reverses the order of values of the receiver.
	public var flip: Either<RightValue, LeftValue> {
		switch self {
		case let .Left(l):
			return .Right(l)
		case let .Right(r):
			return .Left(r)
		}
	}

	/// Determines if this `Either` value is a `Left`.
	public var isLeft: Bool {
		switch self {
		case .Left(_):
			return true
		case .Right(_):
			return false
		}
	}

	/// Determines if this `Either` value is a `Right`.
	public var isRight: Bool {
		switch self {
		case .Right(_):
			return true
		case .Left(_):
			return false
		}
	}
}

extension Either: CustomStringConvertible {
	/// A textual representation of `self`.
	public var description: String {
		switch self {
		case let .Left(l):
			return "Left(\(l))"
		case let .Right(r):
			return "Right(\(r))"
		}
	}
}

public func == <LeftValue: Equatable, RightValue: Equatable>(lhs: Either<LeftValue, RightValue>, rhs: Either<LeftValue, RightValue>) -> Bool {
	switch (lhs, rhs) {
	case let (.Left(l), .Left(r)) where l == r:
		return true
	case let (.Right(l), .Right(r)) where l == r:
		return true
	default:
		return false
	}
}

public func != <LeftValue: Equatable, RightValue: Equatable>(lhs: Either<LeftValue, RightValue>, rhs: Either<LeftValue, RightValue>) -> Bool {
	return !(lhs == rhs)
}
```

## Motivating Examples

Bailing out of a function with a value instead of an exception.

```swift
public enum ArithmeticErrorType: ErrorType {
    case DivideByZero(triedValue: Double)
		// ...
}

public func / (value: Double, by: Double) -> Either<Double, ArithmeticErrorType> {
    if by == 0 {
        return .Right(.DivideByZero(triedValue: value))
    }
    return .Left(value / by)
}
```

A safer and richer bit cast function:

```swift
public enum CastErrorType: ErrorType {
    case BadCast(reason: String)
}

extension Either {
    public static func safeBitCast<T, U>(x: T) -> Either<U, CastErrorType> {
        if let castX = x as? U {
            return .Left(castX)
        }
        return .Right(.BadCast(reason: "Cannot cast value of type \(T.self) to type \(U.self)"))
    }
}
```

(h/t @robrix) Using `Either` to introduce early returns from a call to reduce.

```swift
extension SequenceType {
    /// Return the result of repeatedly calling `combine` with an
    /// accumulated value initialized to `initial` and each element of
    /// `self`, in turn, or until .Right is encountered.
    @warn_unused_result
    public func reduceEarly<T>(initial: T, combine: (T, Self.Generator.Element) -> Either<T, T>) -> T {
        switch self.reduce(Either.Left(initial), combine: { (acc, i) in acc.flatMap { combine($0, i) } }) {
        case let .Left(v):
            return v
        case let .Right(v):
            return v
        }
    }
}
```

For examples of this type in the large, see

- [SwiftCheck](https://github.com/typelift/SwiftCheck/blob/master/SwiftCheck/Test.swift#L468) where it's used to bail out of a bad testing run.
- The parser-combinator framework [Madness](https://github.com/robrix/Madness) and the [Kaleidoscope Language](https://github.com/bencochran/KaleidoscopeLang/blob/master/KaleidoscopeLang/Parser.swift#L102-L129)
it powers.
- Dave Delong's [DDMathParser](https://github.com/davedelong/DDMathParser/blob/master/MathParser/TokenGenerator.swift)
framework's expression tokenizer.
- The JSON parsing framework [Tyro](https://github.com/typelift/Tyro/blob/c611aec772aaf055d5b7c560b5ffe222f9f9f3ad/Tyro/Instances.swift)
for typed errors.
- Typed errors in the core of the [Tesseract](https://github.com/antitypical/TesseractCore) programming language.
- Eigengo's `lift` application for [typed errors](https://github.com/eigengo/lift/blob/master/ios/Lift/Device/Pebble/PebbleDevice.swift).
- Typed errors in [KittyKit](https://github.com/a2/Kitty).

It even makes an appearance (albeit in a different form) in
- [Swift's test suite](https://github.com/apple/swift/blob/master/test/Interpreter/enum.swift#L494-L499).
- [RxSwift](https://github.com/ReactiveX/RxSwift/blob/master/RxSwift/Event.swift)'s eventing mechanism.
- All over [ReactiveCocoa](https://github.com/ReactiveCocoa/ReactiveCocoa) in the form of `Result<T, E>`.
- [And many more](https://github.com/search?utf8=✓&q=Result+language%3Aswift&type=Code&ref=searchresults).

## Impact on existing code

As this is an addition to the Standard Library, no existing code should be affected
unless the author happens to be using the identifier settled on - in which case
there is a strong chance that their Sum type and our Sum type are the same
thing, aligning with the goal of removing duplicate implementations of
this common type.

The fears of the previous proposal that attempted to put a `Result<T>`
type in the Standard Library, of duplicating existing functionality with respect to
`throws` remain, but as noted before `throws` is not as
flexible or declarative enough for all possible cases.  If necessary,
a note can be left in the documentation warning away users of the type that
really need `throws`.

## Alternatives considered

The bias in this definition above may be a sticking point, but the
presence of an unbiased sum type would lead to confusion as to what both
lobes of the type were for.  [As noted in the mailing list](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001423.html), such a type would
be equivalent to `(A?, B?)` with convenience methods to extract values
and induct on the "cases" of each side of the tuple.  As for the matter of
left or right bias, we chose left bias partially because that is the
direction recent programming languages have taken, and partially because
we wish to emphasize the successful case over the failure case.  What
better way than to put it first?

In addition, the name `Either` does not lend much to the imagination,
and the use of `Left` and `Right` have the potential to cause confusion to
novices expecting a `Result<T>` precisely because that particular incarnation of
this type is used mostly for error handling.  If that case were discouraged, and
this type treated like data first, the use of `Left` and `Right` and `Either`
becomes less nebulous.  Mostly, the name does not matter so much as the
structure, so possibilities for a renaming including cases are:

- Result: Value, Error / Success, Error
- Choice: Left, Right / This, That
- Sum: Left, Right
- Alternative: First, Second
- These: This, That
- OneOf: First, Second/This, That
- Variant: First, Second
- Or: Left, Right
- XOr: Left, Right
- Branch: If, Else
- V: Left, Right
- Union: First, Second / Left, Right
- Disjoin: First, Second / Left, Right
- Parity: Even, Odd
