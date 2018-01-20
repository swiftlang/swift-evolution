# NSNumber bridging and Numeric types

* Proposal: [SE-0170](0170-nsnumber_bridge.md)
* Author: [Philippe Hausler](https://github.com/phausler)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 4)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170424/036226.html)

##### Revision history

* **v1** Initial version

## Introduction

`NSNumber` has been a strange duck in the Swift world especially when it has come to bridging and interacting with other protocols. An attempt was made to make a type preserving `NSNumber` subclass; however that defeated numerous optimizations in Foundation and also caused some rather unfortunate disparity between where and how the NSNumbers were created.

## Motivation

Swift should have a consistent experience across all the SDK. No matter if you are using Objective-C in your app/framework in addition to Swift or not the behavior should be easily understood and consistent. Furthermore performance optimizations like tagged pointers or other fast-path accessors in Objective-C or CoreFoundation based code should just work no matter the context in which a `NSNumber` is created.

There are some really spooky behaviors as of current; here are a few extreme examples -

#### Example 1
```swift
let n = NSNumber(value: Int64.max)
if n is Int16 {
    // this is true as of the current build of Swift!
}
```

#### Example 2
```swift
let n = NSNumber(value: Int64.max)
if n is Int16 {
    // this is true as of the current build of Swift!
} else if n is Int64 {
	// Ideally we should get to here
}
```

#### Example 3
```swift
let n = NSNumber(value: Int64(42))
if let value = n as? UInt8 {
    // This makes sense if NSNumber is viewed as an abstract numeric box
}
```

But there are some subtle failures that occur as well -

#### Example 4
```swift
// Serialization behind the scenes causes numeric failures if we were 100% strict
open class MyDocument : NSDocument {
	var myStateValue: Int16 = 0
	
	public static func restoreWindow(withIdentifier identifier: String, state: NSCoder, completionHandler: @escaping (NSWindow?, Error?) -> Swift.Void) {
		myStateValue = state.decodeObject(forKey: "myStateValue") as! Int16 // this is expected to pass since we encoded a Int16 value and we expect at least to get an Int16 out.
	}
	
	open func encodeRestorableState(with coder: NSCoder) {
		coder.encodeObject(myStateValue, forKey: "myStateValue")
	}
}
```

#### Example 5
```swift
// lets say you have a remote server you have no control over except getting JSON requests back
// the format specifies that the response will have a timestamp in a value that is the integral number of milliseconds since 1970
// e.g. { "timestamp" : 1487980252519 } is valid JSON, but a recent server upgrade changes it to be  "timestamp" : 1487980252519.0 } which is also valid JSON

// initially code could be written validly as

let payload = JSONSerialization.jsonObject(with: response, options: []) as? [String : Int]

// but a remote server change could break things if we were strict and requires this code change

let payload = JSONSerialization.jsonObject(with: response, options: []) as? [String : Double]

// But the responses are still integral!

```

#### Example 6
```swift
let itDoesntDoWhatYouThinkItDoes = Int8(NSNumber(value: Int64.max)) // counterintuitively (as legacy baggage of C) this is Int8(-1)
```

All of these examples boil down to the simple question: what does `as?` mean for NSNumber. It is worth noting that `is` should follow the same logic as `as?`.

## Proposed solution

`as?` for NSNumber should mean "Can I safely express the value stored in this opaque box called a NSNumber as the value I want?".

#### Solution Example 1
```swift
// The trivial case of "what you put in the box is what you get out"
let n = NSNumber(value: UInt32(543))
let v = n as? UInt32
// v is UInt32(543)
```

#### Solution Example 2
```swift
// The trivial case of the other way around from Solution Example 1
let v: UInt32 = 543
let n = v as NSNumber
// n == NSNumber(value: 543)
```

#### Solution Example 3
```swift
// Safe "casting"
let n = NSNumber(value: UInt32(543))
let v = n as? Int16
// v is Int16(543)
```

In this case `n` is storing a value of 543 obtained from a `UInt32`. Asking the question "Can I safely express the value stored in this opaque box called a `NSNumber` as the value I want?"; we have 543, can it be expressed safely as a `Int16`? Absolutely!

#### Solution Example 4
```swift
// Failures when casting that lose the value stored
let n = NSNumber(value: UInt32(543))
let v = n as? Int8
// v is nil
```

In this case `n` is storing a value of 543 obtained from a `UInt32` but when asked can it be safely represented as the requested type `Int8` the answer is; of course not.

#### Solution Example 5
```swift
let v = Int8(NSNumber(value: Int64.max))
// v is nil because Int64.max cannot be safely expressed as Int8
```


## Detailed design

The following methods will be changed in swift 4 because the behavior is truncating, not an assertion of exactly:

```swift
extension Int8 {
    init(_ number: NSNumber)
}

extension UInt8 {
    init(_ number: NSNumber)
}

extension Int16 {
    init(_ number: NSNumber)
}

extension UInt16 {
    init(_ number: NSNumber)
}

extension Int32 {
    init(_ number: NSNumber)
}

extension UInt32 {
    init(_ number: NSNumber)
}

extension Int64 {
    init(_ number: NSNumber)
}

extension UInt64 {
    init(_ number: NSNumber)
}

extension Float {
    init(_ number: NSNumber)
}

extension Double {
    init(_ number: NSNumber)
}

extension CGFloat {
    init(_ number: NSNumber)
}

extension Bool {
    init(_ number: NSNumber)
}

extension Int {
    init(_ number: NSNumber)
}

extension UInt {
    init(_ number: NSNumber)
}
```

To the optional variants as such:

```swift
extension Int8 {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension UInt8 {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension Int16 {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension UInt16 {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension Int32 {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension UInt32 {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension Int64 {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension UInt64 {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension Float {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension Double {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension CGFloat {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension Bool {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension Int {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

extension UInt {
    init?(exactly number: NSNumber)
    init(truncating number: NSNumber)
}

```

The behavior of exactly will be an exact bitwise representation for stored integer types such that any initialization must be able to express the initialized type with the stored representation in the NSNumber or it will fail and return nil. The truncating versions on the other hand will be similar to fetching the value via that type accessor. e.g. `Int8(truncating: myNSNumber)` will be tantamount to calling `int8Value `on said number

## Impact on existing code

The one big repercussion is that the bridging methods cannot be versioned for swift 3 and swift 4 availability so we must pick one implementation or another for the bridging. Swift 4 modules or frameworks must bridge in the same manner as Swift 3 since the implementation is the behavioral difference, not the calling module.

There are a number of places in frameworks where NSNumbers are used to provide results. For example CoreData queries can potentially yield NSNumbers, Coding and Archival use NSNumbers for storage under the hood, Serialization uses NSNumbers for numeric representations (there are many more that apply these are just a few that can easily lead to corruption or malformed data when users accidentally truncate via the current bridging behavior). 

Overall I am of the belief that any case that this would break existing code it was potentially incorrect behavior on the part of the developer using the bridge of NSNumber and if it is not the facilities of NSNumber are still present (you can still call `NSNumber(value: Int64.max).int8Value` to get `-1` if that is what you really mean. That way is unambiguous and distinctly clear for maintainable code and reduces the overall magic/spooky behavior.

## Source compatibility

This does change the result of cast via `as?` so it does not change source compatibility but it does change runtime compatibility. In the end, round tripped NSNumbers into collections that bridge across are relatively rare and it is much more common to get NSNumbers out of APIs. The original `as?` cast required developers to be aware of potential failure by syntax, the change here is a safer way of expressing values for all numbers in one uniform methodology that is both more performant as well as more correct in more common cases. In short the runtime effect is a step in the right direction.

## Effect on ABI stability

This change should have no direct impact upon ABI.

## Effect on API resilience

The initializers that had no decoration are marked as deprecated so the remaining portion is considered additive only.

## Considerations for Objective-C platforms

This brings in line the concepts of the existing Objective-C APIs to the intent that was originally used for NSNumber and the usage. Bridging NSNumbers (for platforms that support it and cases that are supported) should always respect the concept of tagged pointers. In just property list cases alone it is approximately a 2% performance loss to avoid the tagged pointer cases; just by using swift there should be little to no performance penalty for sending these types either direction on the bridge in comparison to the equivalent Objective-C implementations.

## Considerations for Linux platforms

We do not have bridging on Linux so the `as?` cast is less important; but if it were to have bridging this would be the desired functionality.

## Alternatives considered

We have explored making NSNumbers created in Swift to be strongly type preserving. This unfortunately results in a severe inconsistency between APIs implemented in Swift and those implemented in Objective-C. Instead of having a disparate behavior depending on the spooky action determined in an opaque framework it is better to have a simple story no matter what language the NSNumber was made in and no matter what facility it was created with. To do so we have only one real way of representing numeric types; meet halfway in the middle between erasing all type information and requiring a pedantic matching of type information and always allow a safe expression of the numeric value.

Using initializers for `Integer` or `FloatingPoint` protocol adopters on NSNumber was considered but was determined out of scope for this change and may be considered separately from the behavior of NSNumber bridging.
