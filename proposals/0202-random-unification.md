# Random Unification

* Proposal: [SE-0202](0202-random-unification.md)
* Authors: [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: [Ben Cohen](http://github.com/AirspeedSwift/)
* Status: **Active Review (March 23...April 3, 2018)**
* Implementation: [apple/swift#12772](https://github.com/apple/swift/pull/12772)

## Introduction

This proposal's main focus is to create a unified random API, and a secure random API for all platforms.

*This idea has been floating around swift-evolution for a while now, but this is the thread that started this proposal: https://forums.swift.org/t/proposal-random-unification/6626*

## Motivation

The current random functionality that Swift provides is through imported C APIs. This of course is dependent on what system is running the code. This means that a different random implementation is provided on a per system basis. Swift relies on Darwin to provide developers the `arc4random(3)` approach. While on Linux, many developers tend to use `random(3)`, from the POSIX standard, or `rand(3)`,  from the C standard library, for a quick and dirty solution for Linux systems. A very common implementation that developers tend to use for quick random functionality is here:

```swift
// This is confusing because some may look at this and think Foundation provides these functions,
// when in reality Foundation imports Darwin and Glibc from which these are defined and implemented.
// You get the same behavior when you import UIKit, or AppKit.
import Foundation

// We can't forget to seed the Linux implementation.
// This is unsecure as time is a very predictable seed.
// This raises more questions to whether or not Foundation, UIKit, or AppKit provided these functions.
#if os(Linux)
srandom(UInt32(time(nil)))
#endif

// We name this randomNumber because random() interferes with Glibc's random()'s namespace
func randomNumber() -> Int {
#if !os(Linux)
  return Int(arc4random()) // This is inefficient as it doesn't utilize all of Int's range
#else
  return random() // or Int(rand())
#endif
}

// Many tend to opt in for ranges here, but for this example I opt for a start and end argument
func random(from start: Int, to end: Int) -> Int {
#if !os(Linux)
  var random = Int(arc4random_uniform(UInt32(end - start)))
#else
  // Not recommended as it introduces modulo bias
  var random = random() % (end - start)
#endif

  random += start

  return random
}

// Alternatively, an easier solution would be:
/*
  func random(from start: Int, to end: Int) -> Int {
    var random = randomNumber() % (end - start)

    random += start

    return random
  }
*/
// However this approach introduces modulo bias for all systems rather than just Linux.
```

While although this does work, it just provides a quick workaround to a much larger outstanding problem. Below is a list outlining the problems the example contains, and the problems the example introduces.

1. In order to define these workarounds, developers must utilize a few platform checks. Developers should not be forced to define platform checks for such trivial requests like this one.

2. Unexperienced developers who rely on workarounds like these, may be pushing unsecure code that is used by tens of hundreds or thousands of users. Starting with Darwin's `arc4random(3)`, pre macOS 10.12 (Sierra) and iOS 10, the implementation of `arc4random(3)` utilized the RC4 algorithm. This algorithm is now considered non-cryptographically secure due to RC4 weakness. Post macOS 10.12 (Sierra) and iOS 10, "...it was replaced with the NIST-approved AES cipher", as stated from the man pages in terminal (`man arc4random`). Moving on to Linux we see that using `random()` or `rand()` to generate numbers make it completely predictable as these weren't designed to be at a crypto level.

3. In the example, it uses modulo to generate the number within the upper bound. Many developers may not realize it, but for a quick workaround, it introduces modulo bias in which modulo does not correctly distribute the probability in dividing the upper bound equally within the range.

4. Highly inefficient as creating a new `Int` from a `UInt32` doesn't utilize the full extent of `Int`'s range.

5. Could confuse some users as Foundation, AppKit, or UIKit don't provide these random functionalities.

Considering all of this, I believe it is very important that Swift provides developers a simple, easy to use, and powerful random API. Although this is out of focus for Swift 5, this proposal solves a huge pain point for many Swift developers.

## Proposed Solution

### Random Number Generator

To kick this off, we will be discussing the rngs that each operating system will utilize. We will make the default random generator cryptographically secure. This means on each operating system, the random api for Swift will produce a secure random number. In addition to being cryptographically secure, the default random generator will also be thread safe. It is also worth noting that if any of the following fail, particularly reading from /dev/urandom, then we produce a fatal error and abort the application. Reasons why I went with this approach in Alternatives Considered at the bottom of this proposal.

#### Darwin Platform

|                    macOS < 10.12, iOS < 10                   |    macOS >= 10.12, iOS >= 10   |
|:------------------------------------------------------------:|:------------------------------:|
|      Use `SecRandomCopyBytes` in the Security framework      |       Use `arc4random(3)`      |

#### Linux Platform

We require that the kernel version be >= 3.17 as this was the release that introduced the `getrandom(2)` system call. We also require that glibc be >= 2.25 because this release exposed the `<sys/random.h>` header.

| Kernel Version < 3.17 && Glibc Version < 2.25 | Kernel Version >= 3.17 && Glibc Version >= 2.25 |
|:---------------------------------------------:|:-----------------------------------------------:|
|            Read from `/dev/urandom`           |                Use `getrandom(2)`               |

#### Other Platforms

| Android (Bionic) and Cygwin |       Fuchsia       |         Windows        |
|:---------------------------:|:-------------------:|:----------------------:|
|      Use `getrandom(2)`     | Use `getentropy(2)` | Use `BCryptoGenRandom` |

### Random API

For the core API, introduce a new protocol named `RandomNumberGenerator`. This type is used to define rngs that can be used within the stdlib. Developers can conform to this type and use their own custom rng throughout their whole application.

Then for the stdlib's default rng implementation, introduce a new struct named `Random`. This struct contains a singleton called `default` which provides access to the methods of `RandomNumberGenerator`.

Next, we will make extension methods for `FixedWidthInteger`, `BinaryFloatingPoint` and `Bool`. For numeric types, this allows developers to select a value within a range and swap out the rng used to select a value within the range.

`FixedWidthInteger` example:
```swift
// Utilizes the standard library's default random (alias to Int.random(in: 0 ..< 10, using: Random.default))
let randomIntFrom0To10 = Int.random(in: 0 ..< 10)
let randomUIntFrom10Through100 = UInt.random(in: 10 ... 100, using: myCustomRandomNumberGenerator)

// The following are examples on how to get full width integers

let randomInt = Int.random(in: .min ... .max)

// an alternative spelling could be:
// let randomUInt = myCustomRandomNumberGenerator.next()
// this takes advantage of the fact that generators can produce unsigned integers
let randomUInt = UInt.random(in: .min ... .max, using: myCustomRandomNumberGenerator)
```

`BinaryFloatingPoint` example:
```swift
// Utilizes the standard library's default random (alias to Float.random(in: 0 ..< 1, using: Random.default))
let randomFloat = Float.random(in: 0 ..< 1)
let randomDouble = Double.random(in: 0 ... .pi, using: myCustomRandomNumberGenerator)
```

`Bool` example:
```swift
// Utilizes the standard library's default random (alias to Bool.random(using: Random.default))
let randomBool1 = Bool.random()
let randomBool2 = Bool.random(using: myCustomRandomNumberGenerator)
```

### Collection Additions

#### Random Element

For `Collection` we add a random method with default implementation for collections to get a random element.

`Collection` example:
```swift
let greetings = ["hey", "hi", "hello", "hola"]

// Utilizes the standard library's default random (alias to greetings.random(using: Random.default))
print(greetings.random() as Any) // This returns an Optional
print(greetings.random(using: myCustomRandomNumberGenerator) as Any) // This returns an Optional
```

#### Shuffle API

As a result of adding the random api, it only makes sense to utilize that power to fuel the shuffle methods. We extend `MutableCollection` to add a method to shuffle the collection itself, and extend `Sequence` to add a method to return a shuffled version of itself in a new array. Example:

```swift
var greetings = ["hey", "hi", "hello", "hola"]

// Utilizes the standard library's default random (alias to greetings.shuffle(using: Random.default))
greetings.shuffle()
print(greetings) // A possible output could be ["hola", "hello", "hey", "hi"]

let numbers = 0 ..< 5
print(numbers.shuffled(using: myCustomRandomNumberGenerator)) // A possible output could be [1, 3, 0, 4, 2]
```

## Detailed Design

The actual implementation can be found here: [apple/swift#12772](https://github.com/apple/swift/pull/12772)

```swift
public protocol RandomNumberGenerator {
  // This determines the functionality for producing a random number.
  // Required to implement by all rngs.
  func next() -> UInt64
}

// These sets of functions are not required and are provided by the stdlib by default
extension RandomNumberGenerator {
  // This function provides generators a way of generating other unsigned integer types
  public func next<T : FixedWidthInteger & UnsignedInteger>() -> T

  // This function provides generators a mechanism for uniformly generating a number from 0 to upperBound
  // Developers can extend this function themselves and create different behaviors for different distributions
  public func next<T : FixedWidthInteger & UnsignedInteger>(upperBound: T) -> T
}

// The stdlib rng
public struct Random : RandomNumberGenerator {
  // Public facing api
  public static let `default` = Random()

  // Prevents initialization of this struct
  private init() {}

  // Conformance for `RandomNumberGenerator`, calls one of the crypto functions.
  public func next() -> UInt64
  
  // We override the protocol defined one to prevent unnecessary work in generating an
  // unsigned integer that isn't a UInt64
  public func next<T: FixedWidthInteger & UnsignedInteger>() -> T
}

public protocol Collection {
  // Returns a random element from the collection
  func random<T: RandomNumberGenerator>(using generator: T) -> Element?
}

// Default implementation
extension Collection {
  // Returns a random element from the collection
  // Can return nil if isEmpty is true
  public func random<T: RandomNumberGenerator>(
    using generator: T
  ) -> Element?
  
  /// Uses the standard library's default rng
  public func random() -> Element? {
    return random(using: Random.default)
  }
}

// We have to add this extension to support syntax like (Int.min ..< Int.max).random()
// That fails because Collection's implementation utilizes the count property and
// from Int.min to Int.max, an Int overflows with that big of a value.
extension Range
where Bound : FixedWidthInteger,
      Bound.Magnitude : UnsignedInteger {
  // Returns a random element within lowerBound and upperBound
  // Can return nil if lowerBound == upperBound
  public func random<T: RandomNumberGenerator>(
    using generator: T
  ) -> Element?
  
  /// Uses the standard library's default rng
  public func random() -> Element? {
    return random(using: Random.default)
  }
}

// We have to add this extension to support syntax like (Int.min ... Int.max).random()
// That fails because Collection's implementation utilizes the count property and
// from Int.min to Int.max, an Int overflows with that big of a value.
extension ClosedRange
where Bound : FixedWidthInteger,
      Bound.Magnitude : UnsignedInteger {
  // Returns a random element within lowerBound and upperBound
  public func random<T: RandomNumberGenerator>(
    using generator: T
  ) -> Element?
  
  /// Uses the standard library's default rng
  public func random() -> Element? {
    return random(using: Random.default)
  }
}

// Enables developers to use things like Int.random(in: 5 ..< 12) which does not use modulo bias.
// This differs from things like (5 ..< 12).random() because those ranges return an Optional, whereas
// this returns a non-optional. Ranges get the benefit of using random, but this is the preferred
// method as it provides a cleaner API to users and clearly expresses the operation.
// It is worth noting that any empty range entered here will abort the program.
// We do this to preserve a general use case design that the core team expressed.
// For those that are that unsure whether or not their range is empty or not,
// they can simply call random from the range itself to produce an Optional, or if/guard check
// whether or not the range is empty beforehand, then use these functions.
extension FixedWidthInteger
where Self.Stride : SignedInteger,
      Self.Magnitude : UnsignedInteger {

  public static func random<T: RandomNumberGenerator>(
    in range: Range<Self>,
    using generator: T
  ) -> Self

  /// Uses the standard library's default rng
  public static func random(in range: Range<Self>) -> Self {
    return Self.random(in: range, using: Random.default)
  }

  public static func random<T: RandomNumberGenerator>(
    in range: ClosedRange<Self>,
    using generator: T
  ) -> Self
  
  /// Uses the standard library's default rng
  public static func random(in range: ClosedRange<Self>) -> Self {
    return Self.random(in: range, using: Random.default)
  }
}

// Enables developers to use things like Double.random(in: 5 ..< 12) which does not use modulo bias.
// This differs from things like (5.0 ..< 12.0).random() because those ranges return an Optional, whereas
// this returns a non-optional. Ranges get the benefit of using random, but this is the preferred
// method as it provides a cleaner API to users and clearly expresses the operation.
// It is worth noting that any empty range entered here will abort the program.
// We do this to preserve a general use case design that the core team expressed.
// For those that are that unsure whether or not their range is empty or not,
// they can simply if/guard check the bounds to make sure they can correctly form
// ranges which a random number can be formed from.
extension BinaryFloatingPoint
where Self.RawSignificand : FixedWidthInteger,
      Self.RawSignificand.Stride : SignedInteger & FixedWidthInteger,
      Self.RawSignificand.Magnitude : UnsignedInteger {

  public static func random<T: RandomNumberGenerator>(
    in range: Range<Self>,
    using generator: T
  ) -> Self

  /// Uses the standard library's default rng
  public static func random(in range: Range<Self>) -> Self {
    return Self.random(in: range, using: Random.default)
  }

  public static func random<T: RandomNumberGenerator>(
    in range: ClosedRange<Self>,
    using generator: T
  ) -> Self
  
  /// Uses the standard library's default rng
  public static func random(in range: ClosedRange<Self>) -> Self {
    return Self.random(in: range, using: Random.default)
  }
}

// We add this as a convenience to something like:
// Int.random(in: 0 ... 1) == 1
// To the unexperienced developer they might have to look at this a few times to
// understand what is going on. This extension methods helps bring clarity to
// operations like these.
extension Bool {
  public static func random<T: RandomNumberGenerator>(
    using generator: T
  ) -> Bool
  
  /// Uses the standard library's default rng
  public static func random() -> Bool {
    return Bool.random(using: Random.default)
  }
}

// Shuffle API

// The shuffle API will utilize the Fisher Yates algorithm

extension Sequence {
  public func shuffled<T: RandomNumberGenerator>(
    using generator: T
  ) -> [Element]
  
  /// Uses the standard library's default rng
  public func shuffled() -> [Element] {
    return shuffled(using: Random.default)
  }
}

extension MutableCollection {
  public mutating func shuffle<T: RandomNumberGenerator>(
    using generator: T
  )
  
  /// Uses the standard library's default rng
  public mutating func shuffle() {
    shuffle(using: Random.default)
  }
}
```

## Source compatibility

This change is purely additive, thus source compatibility is not affected.

## Effect on ABI stability

This change is purely additive, thus ABI stability is not affected.

## Effect on API resilience

This change is purely additive, thus API resilience is not affected.

## Alternatives considered

There were very many alternatives to be considered in this proposal.

### Why would the program abort if it failed to generate a random number?

I spent a lot of time deciding what to do if it failed. Ultimately it came down to the fact that these will almost never fail. In the cases where this can fail is where `/dev/urandom` doesn't exist, or there were too many file descriptors open on the process level or system level. In the case where `/dev/urandom` doesn't exist, either the kernel is too old to generate that file by itself on a fresh install, or a privileged user deleted it. Both of which are way out of scope for Swift in my opinion. In the case where there are too many file descriptors, with modern technology this should almost never happen. If the process has opened too many descriptors then it should be up to the developer to optimize opening and closing descriptors.

In a world where this did return an error to Swift, it would require types like `Int` to return an optional on its static function. This would defeat the purpose of those static functions as it creates a double spelling for the same operation.

```swift
let randomDice = Int.random(in: 1 ... 6)!
// would be equivalent to
// let randomDice = (1 ... 6).random()!
```

"I just want a random dice roll, what is this ! the compiler is telling me to add?"

This syntax wouldn't make sense for a custom rng that deterministically generates numbers with no fail. This also goes against the "general use" design that the core team and much of the community expressed.

Looking at Rust, we can observe that they also abort when an unexpected error occurs with any of the forms of randomness. [source](https://doc.rust-lang.org/rand/src/rand/os.rs.html)

It would be silly to account for these edge cases that would only happen to those who need to update their os, optimize their file descriptors, or deleted their `/dev/urandom`. Accounting for these cases sacrifices the clean api for everyone else.

### Shouldn't this fallback on something more secure at times of low entropy?

Thomas Hühn explains it very well [here](https://www.2uo.de/myths-about-urandom/). There is also a deeper discussion [here talking about python's implementation](https://www.python.org/dev/peps/pep-0524). Both articles discuss that even though /dev/urandom may not have enough entropy at a fresh install, "It doesn't matter. The underlying cryptographic building blocks are designed such that an	attacker cannot predict the outcome." Using `getrandom(2)` on linux systems where the kernel version is >= 3.17, will block if it decides that the entropy pool is too small. In python's implementation, they fallback to reading `/dev/urandom` if `getrandom(2)` decides there is not enough entropy.

### Why not make the default rng non-secure?

Swift is a safe language which means that it shouldn't be encouraging non-experienced developers to be pushing unsecure code. Making the default secure removes this issue and gives developers a feeling of comfort knowing their code is ready to go out of the box.

### Rename `RandomNumberGenerator`

It has been discussed to give this a name such as `RNG`. I went with `RandomNumberGenerator` because it is clear, whereas `RNG` has a level of obscurity to those who don't know the acronym.

### Rename `Collection.random()` to `Collection.randomElement()`

I chose `.random()` over `.randomElement()` here because `.randomElement()` doesn't match with things like `.first`, `.last`, `.min()`, or `.max()`. If the naming for those facilities ended in Element as well, then I would have chosen `.randomElement()`, but to be consistent I chose `.random()`.

### Add static `.random()` to numerical types

There were a bit of discussion for and against this. Initially I was on board with adding this as it provided a rather simple approach to getting full width integers/floating points within the range of `[0, 1)`. However, discussion came up that `Int.random()` encourages the misuse of modulo to get a number within x and y. This is bad because of modulo bias as I discussed in Motivation. For unexperienced developers, they might not know what values are going to be produced from those functions. It would require documentation reading to understand the range at which those functions pick from. They would also have inconsistent ranges that they choose from (`[.min, .max]` for `FixedWidthInteger`s and `[0, 1)` for `BinaryFloatingPoint`s). I thought about this for a very long time and I came to the conclusion that I would rather have a few extra characters than to have the potential for abuse with modulo bias and confusion around the ranges that these functions use.

### Choose `range.random()` over static `.random(in:)`

This was a very heavily discussed topic that we can't skip over.

I think we came into agreement that `range.random()` should be possible, however the discussion was around whether or not this is the primary spelling for getting random numbers. Having a range as the primary spelling makes it fairly simple to get a random number from. Ranges are also very desirable because it doesn't encourage modulo bias. Also, since we decided pretty early on that we're going to trap if for whatever reason we can't get a random number, this gave `range.random()` the excuse to return a non optional.

On the other end of the spectrum, we came into early agreement that `Collection.random()` needs to return an optional in the case of an empty collection. If ranges were the primary spelling, then we would need to create exceptions for them to return non optionals. This would satisfy the general use design, but as we agreed that `.random()` behaves more like `.first`, `.last`, `.min()`, and `.max()`. Because of this, `.random()` has to return an optional to keep the consistent semantics. This justifies the static functions on the numeric types as the primary spelling as they can be the ones to return non optionals. These static functions are also the spelling for how developers think about going about random numbers. "Ok, I need a random integer from x and y." This helps give these functions the upper hand in terms of discoverability.
