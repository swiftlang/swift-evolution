# `nil` Values for Objective-C Primitives

* Proposal: [SE-NNNN](NNNN-nil-values-for-objective-c-primitives.md)
* Author: [Jeff Kelley](https://github.com/SlaunchaMan)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

This proposal aims to improve Swift’s compatibility with Objective-C by allowing Objective-C methods to declare nullability for primitives by using sentinel values. By using the format `nullable(value)`, the syntax will stay close to existing Objective-C nullability specifiers, as well as serving as inline documentation about the method’s behavior.


Swift-evolution thread: [Pitch Discussion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170213/031928.html)

## Motivation

Many Objective-C methods use sentinel values to represent null values, whether it’s `NSNotFound`, an `NSRange` with `NSNotFound` as the location, or even simply returning `-1` for an `NSInteger`. When these methods are used from within Swift, the Swift developer must know the method’s behavior and account for these values in their code. Depending on how well-documented the code is, it can be very easy to miss these values and cause problems down the line.

## Proposed solution

A good example is `NSArray`’s `‑indexOfObject:` method, which could be annotated thusly:

```Objective-C
- (nullable(NSNotFound) NSUInteger)indexOfObject:(ObjectType)anObject;
```

This annotation does two things: first, it documents the behavior that a null value will return as `NSNotFound`, and second, it allows the Swift compiler to convert it to this Swift equivalent:

```Swift
func index(of object: Any) -> Int?
```

Another example is `NSPropertyListSerialization`’s `‑writePropertyList:toStream:format:options:error:` method. This method’s full signature is as follows:

```Objective-C
+ (NSInteger)writePropertyList:(id)plist
                      toStream:(NSOutputStream *)stream
                        format:(NSPropertyListFormat)format
                       options:(NSPropertyListWriteOptions)opt
                         error:(out NSError * _Nullable *)error;
```

Notice that the method returns an `NSInteger`. The very last line of the documentation reads:

> Returns the number of bytes written to the stream. If the value is 0 an error occurred.

This is easy to miss. An annotated version would read as follows:

```Objective-C
+ (nullable(0) NSInteger)writePropertyList:(id)plist
                                  toStream:(NSOutputStream *)stream
                                    format:(NSPropertyListFormat)format
                                   options:(NSPropertyListWriteOptions)opt
                                     error:(out NSError * _Nullable *)error;
```

Here, the first thing the developer sees is that `0` is a null value upon return, and the Swift compiler will treat it as an `Int`, forcing the developer to handle `nil` cases.

Another place where primitives are commonly used is CoreGraphics. Here, we could annotate a method on `CGContext` to return the current point in a non-empty path:

```Objective-C
nullable(CGPointZero) CGPoint CGContextGetPathCurrentPoint(CGContextRef c);
```

From the documentation on this method:

> If there is no path, the function returns `CGPointZero`.

With this annotation, the Swift version would change to:

```Swift
var currentPointOfPath: CGPoint? { get }
```

Making the current point an optional is a more clear way for the API to tell the developer that there may not *be* a current point.

## Detailed design

The design of this feature hinges on the use of `nullable` for primitives in Objective-C. These values are automatically transformed to and from `nil` when calling from Swift code (where exactly this happens is left to the implementation). This could be used in return types and parameters of methods and free functions alike:

```Objective-C
- (nullable(NSNotFound) NSUInteger)indexOfObject:(ObjectType)anObject;

dispatch_queue_t dispatch_get_global_queue(long identifier,
                                           nullable(0ul) unsigned long flags);
```

Another place where this could be useful would be in `typedef` declarations. The aforementioned `NSArray` method could define a new type, `NSArrayIndex`, to handle `nil` values:

```Objective-C
typedef nullable(NSNotFound) NSUInteger NSArrayIndex
```

The advantage to using a `typedef` is that the information is encoded for other methods where the sentinel value is not a valid value to pass:

```Objective-C
- (NSArrayIndex)indexOfObject:(ObjectType)anObject;
- (ObjectType)objectAtIndex:(nonnull NSArrayIndex)index;
```

Using a `typedef` also has an advantage in readability; the `NSPropertyListSerialization` methods above come dangerously close to exceeding the width of many IDE windows.

The use of `nullable()` gets a little more complicated with struct types—what happens with types like `CGRect`? `CGRectNull` exists, but it’s not always clear how to determine if a struct value represents `nil`. `NSRange`, for instance, uses the location `NSNotFound` and a length of `0`, but only the location is used to determine `nil`-ness.

One proposed solution to this is a pair of functions provided to the annotation, one to determine if a value is `nil`, and one to create a `nil` value.

## Source compatibility

As this annotation is used by more Objective-C code, the Swift code calling into it will necessarily need to update in order to compile. Methods that used to return `Int` types will instead return `Int?`, causing additional work to support. However, in these cases, if the developer were already properly accounting for null values using existing conventions, the change should be straightforward. This code:

```Swift
let index = myArray.index(of: "Foo")

if index != NSNotFound { // do something }
```

will need to change to something like so:

```Swift
if let index = myArray.index(of: "Foo") { // do something }
```

Where there are questions around this code is when the sentinel values are used in Swift. Consider this innocent-looking `for` loop:

```Swift
for i in 0 ..< numberOfTimes {
    myObjCObject.doSomething(with: i)
}
```

If the `-doSomethingWithInt:` method of the Objective-C object changes such that `0` is `nil`, what should this code do? At what point is it converted to `nil` so the Swift compiler can catch that you’re passing `nil` to a `nonnull` parameter? If possible, my preference would be to make sending the sentinel an error, with a Fix-It to use `nil` instead for `nullable` values.

## Effect on ABI stability

At first glance, since this change is mostly on the Objective-C side, I don’t *think* this would affect the Swift ABI.

## Effect on API resilience

As with ABI stability, I think this change mostly affects Objective-C, so this shouldn’t impact the API resilience of Swift APIs.

## Alternatives considered

My initial draft featured `NS_SWIFT_NIL()` as the annotation, but a reply used `nullable()` instead and I’ve come to prefer it, as it’s what an Objective-C programmer is already used to using as a nullability specifier. This also allows `nonnull` to be used for annotated types in a straightforward manner.

