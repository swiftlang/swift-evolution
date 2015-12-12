# Add `@noescape` to public library API

* Proposal: [SE-0012](https://github.com/apple/swift-evolution/blob/master/proposals/0012-add-noescape-to-public-library-api.md)
* Author(s): [Jacob Bandes-Storch](https://github.com/jtbandes)
* Status: **Awaiting review**
* Review Manager: [Doug Gregor](https://github.com/DougGregor)

## Introduction

### `@noescape`

Swift provides [a `@noescape` declaration attribute](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/Swift_Programming_Language/Closures.html#//apple_ref/doc/uid/TP40014097-CH11-ID546) which can be applied to closure parameters, indicating that the closure's execution is guaranteed not to escape the function call.

```swift
func withLock(@noescape perform closure: () -> Void) {
    myLock.lock()
    closure()
    myLock.unlock()
}
```

Thus, a closure argument is guaranteed to be executed (if executed at all) *before* the function returns. This enables the compiler to perform various optimizations, such as omitting unnecessary capturing/retaining/releasing of `self`.

For example, just as "`self.`" may be omitted in the context of a method, since a `@noescape` closure is known not to capture `self`, properties and methods can be accessed without the `self.` prefix:

```swift
class MyClass {
    var counter = 0
    
    func incrementCounter() {
        counter += 1  // "self." elided in an instance method
        
        withLock {
            // Without @noescape, the following line would produce the error
            //   "reference to property 'counter' in closure requires
            //    explicit 'self.' to make capture semantics explicit".
            counter += 1
        }
    }
}
```

### In C and Objective-C

Clang understands the `noescape` attribute, spelled `__attribute__((noescape))` or `__attribute__((__noescape__))`. When function definitions whose block or function-pointer parameters have this attribute are imported to Swift, they are visible with a Swift `@noescape` attribute.

```c
void performWithLock(__attribute__((noescape)) void (^block)()) {  // exposed as @noescape to Swift
    lock(myLock);
    block();
    unlock(myLock);
}
```


```objective-c
- (void)performWithLock:(__attribute__((noescape)) void (^)())block {  // exposed as @noescape to Swift
    [myLock lock];
    block();
    [myLock unlock];
}
```

## Motivation

Many standard methods and functions — particularly in Foundation and libdispatch — have non-escaping closure semantics, but **do not have `__attribute__((noescape))`**. This thwarts the compiler optimizations and syntax shortcuts granted by `@noescape`, when they should otherwise be applied.

In pure Swift, there is no workaround, but by writing some custom C/Objective-C wrapper functions, users can work around these limitations:

```objective-c
// MyProject-Bridging-Header.h

NS_INLINE void MyDispatchSyncWrapper(dispatch_queue_t queue, __attribute__((noescape)) dispatch_block_t block)
{
    dispatch_sync(queue, block);
}
```

However, it's clear that library functions with non-escaping semantics should be marked with the `noescape` attribute at the source, so that users don't have to wrap every function they'd like to use.

## Proposed solution

1. Audit system C/Objective-C libraries (stdlib, libdispatch, Foundation, ...) for functions and methods with closure parameters that are guaranteed not to escape the lifetime of the call.
   - *See the end of this document for a comprehensive list of candidate functions/methods.*
2. Annotate such functions and methods' block/function-pointer parameters with `__attribute__((noescape))`.
3. For libraries with Swift-specific forks (like [swift-corelibs-libdispatch](https://github.com/apple/swift-corelibs-libdispatch)), the change should be made in the Apple-internal upstream version as well.

###### Example patch

An example patch to libdispatch can be seen at https://github.com/apple/swift-corelibs-libdispatch/pull/6/files.

## Impact on existing code

Users who previously used functions which are newly `@noescape` may have unnecessary instances of `self.` in their code. However, there should be no breaking syntax changes and no functional difference.

## Alternatives considered

The Swift compiler's support for supplementary "API notes" (`.apinotes` files) could be extended and used to annotate closure parameters as non-escaping.

However, I believe it's better to put annotations in headers for the following reasons:
- The presence of `__attribute__((noescape))` in library headers clarifies API contracts, and encourages users to use this attribute in their own code where applicable.
- With apinotes, the benefits to Swift would be limited to specific libraries and functions, leaving annotation in the hands of the Swift compiler project. Given a version of a library with annotated headeres, however, no extra compiler configuration is required to take advantage of the annotation.
- As Clang itself improves, the benefits of `__attribute__((noescape))` can be granted to Objective-C callers as well as Swift (for example, by suppressing `-Wimplicit-retain-self` &lt;rdar://19914650>).

## Comprehensive list of methods/functions with non-escaping block parameters

Note that Objective-C library methods tend to come in three variants:
- "[elements] passing test"
- "[sorted] using comparator"
- "enumerate using block/function"

### stdlib

- `bsearch()`, `bsearch_b()`
- `heapsort()`, `heapsort_b()`
- `mergesort()`, `mergesort_b()`
- `psort()`, `psort_b()`
- `qsort()`, `qsort_b()`


### libdispatch

- `dispatch_apply()`, `dispatch_apply_f()`
- `dispatch_barrier_sync()`, `dispatch_barrier_sync_f()`
- `dispatch_block_perform()`
- `dispatch_data_apply()`
- `dispatch_once()`, `dispatch_once_f()`
- `dispatch_sync()`, `dispatch_sync_f()`

### CoreFoundation

- `CFArrayBSearchValues()`
- `CFArraySortValues()`
- `CFTreeSortChildren()`


### Foundation

###### "Passing test" methods
- `-[NSArray indexOfObjectPassingTest:]`
- `-[NSArray indexOfObjectsAtIndexes:passingTest:]`
- `-[NSArray indexesOfObjectsAtIndexes:passingTest:]`
- `-[NSArray indexesOfObjectsPassingTest:]`
- `-[NSDictionary keysOfEntriesPassingTest:]`
- `-[NSDictionary keysOfEntriesWithOptions:passingTest:]`
- `-[NSIndexSet indexInRange:options:passingTest:]`
- `-[NSIndexSet indexPassingTest:]`
- `-[NSIndexSet indexWithOptions:passingTest:]`
- `-[NSIndexSet indexesInRange:options:passingTest:]`
- `-[NSIndexSet indexesPassingTest:]`
- `-[NSIndexSet indexesWithOptions:passingTest:]`
- `-[NSOrderedSet indexOfObjectPassingTest:]`
- `-[NSOrderedSet indexOfObjectsAtIndexes:passingTest:]`
- `-[NSOrderedSet indexesOfObjectsAtIndexes:passingTest:]`
- `-[NSOrderedSet indexesOfObjectsPassingTest:]`
- `-[NSSet objectsPassingTest:]`
- `-[NSSet objectsWithOptions:passingTest:]`

###### "Using comparator/function" methods
- `-[NSArray indexOfObject:inSortedRange:options:usingComparator:]`
- `-[NSArray sortedArrayUsingComparator:]`
- `-[NSArray sortedArrayUsingFunction:context:]`
- `-[NSArray sortedArrayUsingFunction:context:hint:]`
- `-[NSArray sortedArrayWithOptions:usingComparator:]`
- `-[NSDictionary keysSortedByValueUsingComparator:]`
- `-[NSDictionary keysSortedByValueWithOptions:usingComparator:]`
- `-[NSMutableArray sortUsingComparator:]`
- `-[NSMutableArray sortUsingFunction:context:]`
- `-[NSMutableArray sortWithOptions:usingComparator:]`
- `-[NSMutableOrderedSet sortRange:options:usingComparator:]`
- `-[NSMutableOrderedSet sortWithOptions:usingComparator:]`

###### "Enumerate using block" methods
- `-[NSArray enumerateObjectsUsingBlock:]`
- `-[NSArray enumerateObjectsWithOptions:usingBlock:]`
- `-[NSData enumerateByteRangesUsingBlock:]`
- `-[NSDictionary enumerateKeysAndObjectsUsingBlock:]`
- `-[NSDictionary enumerateKeysAndObjectsWithOptions:usingBlock:]`
- `-[NSIndexSet enumerateIndexesUsingBlock:]`
- `-[NSIndexSet enumerateIndexesWithOptions:usingBlock:]`
- `-[NSIndexSet enumerateRangesInRange:options:usingBlock:]`
- `-[NSIndexSet enumerateRangesUsingBlock:]`
- `-[NSIndexSet enumerateRangesWithOptions:usingBlock:]`
- `-[NSOrderedSet enumerateObjectsUsingBlock:]`
- `-[NSOrderedSet enumerateObjectsWithOptions:usingBlock:]`
- `-[NSSet enumerateObjectsUsingBlock:]`
- `-[NSSet enumerateObjectsWithOptions:usingBlock:]`
- `-[NSString enumerateLinesUsingBlock:]`
- `-[NSString enumerateSubstringsInRange:options:usingBlock:]`

### Other

The AVFoundation, SceneKit, SpriteKit, AppKit, and MediaPlayer frameworks have methods that could also use `__attribute__((noescape))`, but those are considered outside the scope of this proposal.
