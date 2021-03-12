# Allow interchangeable use of `CGFloat` and `Double` types

* Proposal: [SE-0307](0307-allow-interchangeable-use-of-double-cgfloat-types.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Scheduled for Review (March 15 - 23 2021)**
* **Implementation:** PR https://github.com/apple/swift/pull/34401 based on the `main` branch. Toolchains are available for [macOS](https://ci.swift.org/job/swift-PR-toolchain-osx/876//artifact/branch-main/swift-PR-34401-876-osx.tar.gz) and [Linux](https://ci.swift.org/job/swift-PR-toolchain-Linux/552//artifact/branch-main/swift-PR-34401-552-ubuntu16.04.tar.gz).

## Introduction

I propose to extend the language and allow Double and CGFloat types to be used interchangeably by means of transparently converting one type into the other as a sort of retroactive typealias between these two types.  This is a _narrowly_ defined implicit conversion intended to be part of the _existing family_ of implicit conversions (including NSType <=> CFType conversions) supported by Swift to strengthen Objective-C and Swift interoperability. The only difference between the proposed conversion and existing ones is related to the fact that interchangeability implies both narrowing conversion (`Double` -> `CGFloat`) and widening one (`CGFloat` -> `Double`) on 32-bit platforms. This proposal is not about generalizing support for implicit conversions to the language.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/pitch-allow-interchangeable-use-of-cgfloat-and-double-types/45324)


## Motivation

When Swift was first released, the type of `CGFloat` presented a challenge. At the time, most iOS devices were still 32-bit. SDKs such as CoreGraphics provided APIs that took 32-bit floating point values on 32-bit platforms, and 64-bit values on 64-bit platforms. When these APIs were first introduced, 32-bit scalar arithmetic was faster on 32-bit platforms, but by the time of Swift’s release, this was no longer true: then, as today, 64-bit scalar arithmetic was just as fast as 32-bit even on 32-bit platforms (albeit with higher memory overhead). But the 32/64-bit split remained, mostly for source and ABI stability reasons.

In (Objective-)C, this had little developer impact due to implicit conversions, but Swift did not have implicit conversions. A number of options to resolve this were considered:

1. Keep `CGFloat` as a separate type, with explicit conversion from both `Float` and `Double` always needed on all platforms.
2. Do that, but introduce specific implicit conversions from `Double` to `CGFloat`.
3. Make `CGFloat` a typealias for either `Float` or `Double` based on the platform.
4. Consolidate on `Double` for all APIs using `CGFloat`, even on 32-bit platforms, with the Swift importer converting 32-bit `CGFloat` APIs to use `Double`, with the importer adding the conversion.

One important goal was avoiding the need for users to build for both 32- and 64-bit platforms in order to know their code will work on both, so option 3 was ruled out. Option 4 was not chosen mainly because of concern over handling of pointers to `CGFloat` (including arrays). Option 2 was ruled out due to challenges in the type-checker. So option 1 was chosen.

With several years’ hindsight and technical improvements, we can reevaluate these choices. 64-bit devices are now the norm, and even on 32-bit `Double` is now often the better choice for calculations. The concern around arrays or pointers to `CGFloat` turns out to be a minor concern as there are not many APIs that take them. And in the recent top-of-tree Swift compiler, the performance of the type-checker has significantly improved.

As the world has moved on, the choice of creating a separate type has become a significant pain point for Swift users. As the language matured and new frameworks, such as SwiftUI, have been introduced, `CGFloat` has resulted in a significant impedance mismatch, without bringing any real benefit. Many newly introduced APIs have standardized on using `Double` in their arguments.  Because of this discrepancy, it’s not always possible to choose a “correct” type while declaring variables, so projects end up with a mix-and-match of `Double` and `CGFloat` declarations, with constant type conversions (or refactoring of variable types) needed. This constant juggling of types is particularly frustrating given in practice the types are transparently identical to the compiler when building for 64-bit platforms. And when building for 32-bit platforms, the need to appease the type-checker with the API at hand is the overriding driver of conversions, rather than considerations of precision versus memory use that would in theory be the deciding factor.

## Proposed Solution

In order to address all of the aforementioned problems, I propose to extend the language and allow `Double` and `CGFloat` types to be used interchangeably by means of transparently converting one type into the other as a sort of retroactive `typealias` between these two types. This is option 2 in the list above. 

The compiler already implements similar conversions to improve interoperability ergonomics for types from CoreFoundation and Foundation, such as `CFString` <-> `NSString`. The difference between existing interchangeability conversions and the one proposed by this document lays in fact that new conversion implies both implicit widening (`CGFloat` to `Double`) and narrowing (`Double` to `CGFloat`) on 32-bit platforms, which results in loss of precision in the latter case. Precision loss could be deemed acceptable because users of the affected APIs incur it already by means of explicit conversions when passing `Double` values to APIs that expect `CGFloat` arguments (see `Detailed Design` section for more information regarding precision loss mitigation), and since `CGFloat` is a type that is defined by Apple frameworks, it makes this change specific to Apple platforms and a targeted conversion to address a particular ergonomics issue with `Double` and `CGFloat` types.

Let’s consider an example where such a conversion might be useful in the real world:

```
import UIKit

struct Progress {
  let startTime: Date
  let duration: TimeInterval
  
  func drawPath(in rect: CGRect) -> UIBezierPath {
    let elapsedTime = Date().timeIntervalSince(startTime)
    let progress = min(elapsedTime / duration, 1.0)
        
    let path = CGMutablePath()
        
    let center = CGPoint(x: rect.midX, y: rect.midY)
    path.move(to: center)
    path.addLine(to: CGPoint(x: center.x, y: 0))
        
    let adjustment = .pi / 2.0
    path.addRelativeArc(center: center, radius: rect.width / 2.0, 
                        startAngle: CGFloat(0.0 - adjustment), 
                        delta: CGFloat(2.0 * .pi * progress))
    path.closeSubpath()
        
    return UIBezierPath(cgPath: path)
  }
}
```

Here, the `Progress` struct draws a progress circle given a start time and a duration. In Foundation, seconds are expressed using `[TimeInterval](https://developer.apple.com/documentation/foundation/timeinterval)`, which is a typealias for `Double`. However, the `[CGMutablePath](https://developer.apple.com/documentation/coregraphics/cgmutablepath)` APIs for drawing shapes require `CGFloat` arguments, forcing developers to explicitly convert between `Double` and `CGFloat` when working with these two frameworks together. Furthermore, because float literals default to `Double` in Swift, developers are forced to either explicitly annotate or convert simple constants when working with graphics APIs, such as `adjustment` in the above example. With an implicit conversion between `Double` and `CGFloat`, the call to `addRelativeArc` can be simplified to:

```
path.addRelativeArc(center: center, radius: rect.width / 2.0, 
                    startAngle: 0.0 - adjustment,
                    delta: 2.0 * .pi * progress)
```

## Detailed Design

The type-checker will detect all of the suitable locations where `Double` is converted to  `CGFloat` and vice versa and allow such conversion by inserting an implicit initializer call to the appropriate constructor - `(_: CGFloat) -> Double` or `(_: Double) -> CGFloat` depending on conversion direction.

This new conversion has the following properties:

* `Double` is always preferred over `CGFloat` where possible, in order to limit possibility of ambiguities, i.e. an overload that accepts a `Double` argument would be preferred over one that accepts a `CGFloat` if both require a conversion to type-check;
* `Double` ↔ `CGFloat` conversion is introduced only if it has been determined by the type-checker that it would be impossible to type-check an expression without one;
* Any number of widening conversions (`CGFloat` → `Double`)  is preferred over a single narrowing one (`Double` → `CGFloat`), and if narrowing is still contextually necessary, it would be attempted as late as possible to mitigate precision loss. 
    * Let’s consider following example: `let _: CGFloat = x / y` (where `x` is `CGFloat` and `y` is `Double`). Type-checked expression would be `let _: CGFloat = CGFloat.init(x / Double(y)` and not `let _: CGFloat = CGFloat(x) / y` to mitigate potential precision loss.
* Disallowed conversions:
    * Arguments of explicit calls to the `CGFloat` initializer;
    * Collections: arrays, sets, or dictionaries containing `CGFloat` or `Double` keys/values have to be explicitly converted by the user. Otherwise, implicit conversion could hide memory/cpu cost associated with per-element transformations;
    * Explicit (conditional and checked) casts (`try`, `as` etc.) and runtime checks (`is`);
    * Any position where such a conversion has already been introduced; to prevent converting back and forth between `Double` and `CGFloat` by means of other types.


Note that with the introduction of this new conversion, homogeneous overloads can be called with heterogeneous arguments, because it is possible to form a call that accepts both `Double` and `CGFloat` types or a combination thereof. This is especially common with operators.

Let’s consider following example:

```
func sum(_: Double, _: Double) → Double { ... }
func sum(_: CGFloat, _: CGFloat) → CGFloat { ... }

var x: Double = 0
var y: CGFloat = 42

_ = sum(x, y)
```

Although both overloads of `sum` are homogeneous, and under current rules the call is not going to be accepted, with introduction of `Double`  ↔ `CGFloat` conversion it’s possible to form two valid calls depending on what conversion direction is picked. Since it has been established that going `CGFloat` → `Double` is always preferred, `sum(x, y)`  is going to be type-checked as `(Double, Double) -> Double` (because there is no contextual type specified) and arguments are going to be `x` and `Double(y)`. 

The contextual type doesn’t affect the preferred conversion direction since the type-checker would always choose a solution with the fewest number of narrowing conversions possible, i.e.:

```
let _: CGFloat = sum(x, y)
```

`sum(Double, Double) -> Double` is preferred in this case because it requires a single narrowing conversion at the last possible moment, so the type-checked expression would be `let _: CGFloat = CGFloat.init(sum(x, `Double(`y)))`. Such solution is numerically better than any other solution with fewer conversions where narrowing happens in the arguments i.e. `let _: CGFloat = sum(CGFloat(x), y)` because it incurs a more significant precision loss. 

## Source compatibility

This is an additive change and does not have any material effect on source compatibility. This change has been tested on a very large body of code, and all of the expressions that previously type-checked with explicit conversions continued to do so.

## Effect on ABI stability

This change introduces new conversions at compile-time only, and so would not impact ABI. 

## Effect on API resilience

This is not an API-level change and would not impact resilience.

## Alternatives Considered

Not to make this change and leave the painful ergonomics of the `CGFloat` type intact.

Restrict implicit conversions to “API boundaries” only. Such a rule would either imply the same behavior as proposed if operators/functions accept `CGFloat` arguments or introduce arbitrary restrictions like allowing conversions only across module boundaries or resilient ABIs, which would lead to confusing and inconsistent behavior where some calls would fail to type-check without an explicit conversion for no apparent reason (e.g. after an application has been refactored and slit into multiple modules or vice versa).
 
Another possible alternative would be to add new matching `Double` overloads to all APIs that currently accept `CGFloat` type. Such new APIs cannot be backward deployed unless they’re emitted directly into client binaries. In addition to bloating code size, this would also severely impact type checker performance much more than a targeted implicit conversion. 

A more general solution to type conversions may have provided a path to resolve this problem, but only partly. One could propose a language feature that permits implicit widening conversions – for example, from `Int8` to `Int`, or `Float` to `Double`, but not vice versa. Such a general language feature could allow user-defined (in this case CoreGraphics-defined) implicit conversion from, say, `Double` to `CGFloat` on 64-bit platforms, but probably not two-way conversion (`CGFloat` to `Double`) nor would it allow a narrowing conversion from `Double` to 32-bit `CGFloat`. This would result in users writing code for 64-bit platforms, but then finding their code does not compile for 32-bit platforms, and avoiding this remains a core goal for `CGFloat`. So instead, we propose a custom solution for `CGFloat`. Custom solutions like this are undesirable in general, but in this case the benefits to users and the ecosystem in general vastly weigh in its favor. That said, this general “implicit widening” has a lot of appeal, and the work done here with `CGFloat` does prove at least that these kind of implicit conversions can be handled by the Swift type-checker as it exists today.

The choice of not converting arrays was deliberate, but does not match the current behavior with subtype conversions such as `[T] as [Any]`. Since graphical code involving buffers of `CGFloat` may be more performance, explicit conversion is preferred. This need for explicit conversion will likely lead the user to a more efficient solution of building an explicitly typed array instead in the first place, avoiding a linear conversion. The memory implications on 32-bit platforms are also likely to me most material when dealing with large buffers of values, again suggesting explicit conversion is preferable. There are relatively few APIs that traffic in buffers of `CGFloat` so this is not expected to be a concern.


## Acknowledgments

[Holly Borla](https://forums.swift.org/u/hborla) and [Ben Cohen](https://forums.swift.org/u/Ben_Cohen) for all the help with writing and editing this proposal. Also [Xiaodi Wu](https://forums.swift.org/u/xwu) and other participants of the pitch discussion on Swift Forums.
