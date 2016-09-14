# Add `@noescape` to public library API

* Proposal: [SE-0012](0012-add-noescape-to-public-library-api.md)
* Author: [Jacob Bandes-Storch](https://github.com/jtbandes)
* Review Manager: [Philippe Hausler](https://github.com/phausler)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160530/019902.html)

##### Revision history

* **v1** Initial version
* **v1.2** Updates after component owners review and discussion

## Summary

* Swift provides the `@noescape` declaration attribute which indicates that a closure's execution is guaranteed not to escape the function call.
* clang also provides support for this via a “noescape” attribute, which is automatically imported into Swift as @noescape
*  We propose exposing this attribute in CF and Foundation as `CF_NOESCAPE` and `NS_NOESCAPE`
*  We also propose applying this declaration to a number of closure-taking APIs in CF and Foundation 

[Swift Evolution Discussion Thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160201/009270.html)

## Introduction

### `@noescape`

Swift provides a `@noescape` declaration [attribute](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/Swift_Programming_Language/Closures.html#//apple_ref/doc/uid/TP40014097-CH11-ID546) which can be applied to closure parameters, indicating that the closure's execution is guaranteed not to escape the function call.

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

1. Audit system C/Objective-C libraries (libdispatch, Foundation, ...) for functions and methods with closure parameters that are guaranteed not to escape the lifetime of the call.
   - *See the end of this document for a proposed list of candidate functions/methods.*
2. Annotate such functions and methods' block/function-pointer parameters with `__attribute__((noescape))` via a macro where appropriate.
3. Add a new macro in a common area (CoreFoundation/Foundation) to provide a compiler support braced use of this attribute. This macro will allow higher level frameworks and applications to adopt this annotation where appropriate.
4. For libraries with Swift-specific forks (like [swift-corelibs-libdispatch](https://github.com/apple/swift-corelibs-libdispatch)), the change should be made in the Apple-internal upstream version as well.


###### Example patch

An example patch to libdispatch can be seen at https://github.com/apple/swift-corelibs-libdispatch/pull/6/files.

## Impact on existing code

Users who previously used functions which are newly `@noescape` may have unnecessary instances of `self.` in their code. However, there should be no breaking syntax changes and no functional difference.

## Alternatives considered

The Swift compiler's support for supplementary "API notes" (`.apinotes` files) could be extended and used to annotate closure parameters as non-escaping.

However, I believe it's better to put annotations in headers for the following reasons:
- The presence of `__attribute__((noescape))` in library headers clarifies API contracts, and encourages users to use this attribute in their own code where applicable.
- With apinotes, the benefits to Swift would be limited to specific libraries and functions, leaving annotation in the hands of the Swift compiler project. Given a version of a library with annotated headers, however, no extra compiler configuration is required to take advantage of the annotation.
- As Clang itself improves, the benefits of `__attribute__((noescape))` can be granted to Objective-C callers as well as Swift (for example, by suppressing `-Wimplicit-retain-self` &lt;rdar://19914650>).

## CoreFoundation

CoreFoundation will now provide a macro for annotating noescape methods and the following public functions will be annotated accordingly:

```c
#if __has_attribute(noescape)
#define CF_NOESCAPE __attribute__((noescape))
#else
#define CF_NOESCAPE
#endif
```

### CFArray

```c
void CFArrayApplyFunction(CFArrayRef theArray, CFRange range, CFArrayApplierFunction CF_NOESCAPE applier, void *context);
```

### CFBag

```c
void CFBagApplyFunction(CFBagRef theBag, CFBagApplierFunction CF_NOESCAPE applier, void *context);
```

### CFDictionary

```c
void CFDictionaryApplyFunction(CFDictionaryRef theDict, CFDictionaryApplierFunction CF_NOESCAPE applier, void *context);
```

### CFSet

```c
void CFSetApplyFunction(CFSetRef theSet, CFSetApplierFunction CF_NOESCAPE applier, void *context);
```

### CFTree

```c
void CFTreeApplyFunctionToChildren(CFTreeRef tree, CFTreeApplierFunction CF_NOESCAPE applier, void *context);
```

## Foundation

Foundation will provide the following macro and methods annotated accordingly:

```objc
#define NS_NOESCAPE CF_NOESCAPE
```

### NSArray

```objc
- (NSArray<ObjectType> *)sortedArrayUsingFunction:(NSInteger (NS_NOESCAPE *)(ObjectType, ObjectType, void * _Nullable))comparator context:(nullable void *)context;

- (NSArray<ObjectType> *)sortedArrayUsingFunction:(NSInteger (NS_NOESCAPE *)(ObjectType, ObjectType, void * _Nullable))comparator context:(nullable void *)context hint:(nullable NSData *)hint;

- (void)enumerateObjectsUsingBlock:(void (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (void)enumerateObjectsWithOptions:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (void)enumerateObjectsAtIndexes:(NSIndexSet *)s options:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (NSUInteger)indexOfObjectPassingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSUInteger)indexOfObjectWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSUInteger)indexOfObjectAtIndexes:(NSIndexSet *)s options:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSIndexSet *)indexesOfObjectsPassingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSIndexSet *)indexesOfObjectsWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSIndexSet *)indexesOfObjectsAtIndexes:(NSIndexSet *)s options:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSArray<ObjectType> *)sortedArrayUsingComparator:(NSComparator NS_NOESCAPE)cmptr NS_AVAILABLE(10_6, 4_0);

- (NSArray<ObjectType> *)sortedArrayWithOptions:(NSSortOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmptr NS_AVAILABLE(10_6, 4_0);

- (NSUInteger)indexOfObject:(ObjectType)obj inSortedRange:(NSRange)r options:(NSBinarySearchingOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmp NS_AVAILABLE(10_6, 4_0); // binary search
```

### NSMutableArray

```objc
- (void)sortUsingFunction:(NSInteger (NS_NOESCAPE *)(ObjectType,  ObjectType, void * _Nullable))compare context:(nullable void *)context;

- (void)sortUsingComparator:(NSComparator NS_NOESCAPE)cmptr NS_AVAILABLE(10_6, 4_0);

- (void)sortWithOptions:(NSSortOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmptr NS_AVAILABLE(10_6, 4_0);

```

### NSAttributedString

```objc
- (void)enumerateAttributesInRange:(NSRange)enumerationRange options:(NSAttributedStringEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE  ^)(NSDictionary<NSString *, id> *attrs, NSRange range, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (void)enumerateAttribute:(NSString *)attrName inRange:(NSRange)enumerationRange options:(NSAttributedStringEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(id _Nullable value, NSRange range, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);
```

### NSCalendar

```objc
- (void)enumerateDatesStartingAfterDate:(NSDate *)start matchingComponents:(NSDateComponents *)comps options:(NSCalendarOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSDate * _Nullable date, BOOL exactMatch, BOOL *stop))block NS_AVAILABLE(10_9, 8_0);
```

### NSData

```objc
- (void) enumerateByteRangesUsingBlock:(void (NS_NOESCAPE ^)(const void *bytes, NSRange byteRange, BOOL *stop))block NS_AVAILABLE(10_9, 7_0);
```

### NSDictionary

```objc
- (void)enumerateKeysAndObjectsUsingBlock:(void (NS_NOESCAPE ^)(KeyType key, ObjectType obj, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (void)enumerateKeysAndObjectsWithOptions:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(KeyType key, ObjectType obj, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (NSArray<KeyType> *)keysSortedByValueUsingComparator:(NSComparator NS_NOESCAPE)cmptr NS_AVAILABLE(10_6, 4_0);

- (NSArray<KeyType> *)keysSortedByValueWithOptions:(NSSortOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmptr NS_AVAILABLE(10_6, 4_0);

- (NSSet<KeyType> *)keysOfEntriesPassingTest:(BOOL (NS_NOESCAPE ^)(KeyType key, ObjectType obj, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSSet<KeyType> *)keysOfEntriesWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(KeyType key, ObjectType obj, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);
```

### NSIndexSet

```objc
- (void)enumerateIndexesUsingBlock:(void (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (void)enumerateIndexesWithOptions:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (void)enumerateIndexesInRange:(NSRange)range options:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (NSUInteger)indexPassingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSUInteger)indexWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSUInteger)indexInRange:(NSRange)range options:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSIndexSet *)indexesPassingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSIndexSet *)indexesWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSIndexSet *)indexesInRange:(NSRange)range options:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (void)enumerateRangesUsingBlock:(void (NS_NOESCAPE ^)(NSRange range, BOOL *stop))block NS_AVAILABLE(10_7, 5_0);

- (void)enumerateRangesWithOptions:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSRange range, BOOL *stop))block NS_AVAILABLE(10_7, 5_0);

- (void)enumerateRangesInRange:(NSRange)range options:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSRange range, BOOL *stop))block NS_AVAILABLE(10_7, 5_0);
```

### NSLinguisticTagger

```objc
- (void)enumerateTagsInRange:(NSRange)range scheme:(NSString *)tagScheme options:(NSLinguisticTaggerOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSString *tag, NSRange tokenRange, NSRange sentenceRange, BOOL *stop))block NS_AVAILABLE(10_7, 5_0);

- (void)enumerateLinguisticTagsInRange:(NSRange)range scheme:(NSString *)tagScheme options:(NSLinguisticTaggerOptions)opts orthography:(nullable NSOrthography *)orthography usingBlock:(void (NS_NOESCAPE ^)(NSString *tag, NSRange tokenRange, NSRange sentenceRange, BOOL *stop))block NS_AVAILABLE(10_7, 5_0);
```

### NSMetadataQuery

```objc
- (void)enumerateResultsUsingBlock:(void (NS_NOESCAPE ^)(id result, NSUInteger idx, BOOL *stop))block NS_AVAILABLE(10_9, 7_0);

- (void)enumerateResultsWithOptions:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(id result, NSUInteger idx, BOOL *stop))block NS_AVAILABLE(10_9, 7_0);
```

### NSOrderedSet

```objc
- (void)enumerateObjectsUsingBlock:(void (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))block;

- (void)enumerateObjectsWithOptions:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))block;

- (void)enumerateObjectsAtIndexes:(NSIndexSet *)s options:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))block;

- (NSUInteger)indexOfObjectPassingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate;

- (NSUInteger)indexOfObjectWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate;

- (NSUInteger)indexOfObjectAtIndexes:(NSIndexSet *)s options:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate;

- (NSIndexSet *)indexesOfObjectsPassingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate;

- (NSIndexSet *)indexesOfObjectsWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate;

- (NSIndexSet *)indexesOfObjectsAtIndexes:(NSIndexSet *)s options:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))predicate;

- (NSUInteger)indexOfObject:(ObjectType)object inSortedRange:(NSRange)range options:(NSBinarySearchingOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmp; // binary search

- (NSArray<ObjectType> *)sortedArrayUsingComparator:(NSComparator NS_NOESCAPE)cmptr;

- (NSArray<ObjectType> *)sortedArrayWithOptions:(NSSortOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmptr;

```

### NSMutableOrderedSet

```objc
- (void)sortUsingComparator:(NSComparator NS_NOESCAPE)cmptr;

- (void)sortWithOptions:(NSSortOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmptr;

- (void)sortRange:(NSRange)range options:(NSSortOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmptr;
```

### NSRegularExpression

```objc
- (void)enumerateMatchesInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range usingBlock:(void (NS_NOESCAPE ^)(NSTextCheckingResult * _Nullable result, NSMatchingFlags flags, BOOL *stop))block;
```

### NSSet

```objc
- (void)enumerateObjectsUsingBlock:(void (NS_NOESCAPE ^)(ObjectType obj, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (void)enumerateObjectsWithOptions:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(ObjectType obj, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);

- (NSSet<ObjectType> *)objectsPassingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);

- (NSSet<ObjectType> *)objectsWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (NS_NOESCAPE ^)(ObjectType obj, BOOL *stop))predicate NS_AVAILABLE(10_6, 4_0);
```

### NSString

```objc
- (void)enumerateSubstringsInRange:(NSRange)range options:(NSStringEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSString * _Nullable substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);
- (void)enumerateLinesUsingBlock:(void (NS_NOESCAPE ^)(NSString *line, BOOL *stop))block NS_AVAILABLE(10_6, 4_0);
```
