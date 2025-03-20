# Better Translation of Objective-C APIs Into Swift

* Proposal: [SE-0005](0005-objective-c-name-translation.md)
* Authors: [Doug Gregor](https://github.com/DougGregor), [Dave Abrahams](https://github.com/dabrahams)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3.0)**
* Decision Notes: [Rationale](https://forums.swift.org/t/accepted-with-modification-se-0005-better-translation-of-objective-c-apis-into-swift/1668)

## Reviewer notes

This review is part of a group of three related reviews, running
concurrently:

* [SE-0023 API Design Guidelines](0023-api-guidelines.md)
  ([Review](https://forums.swift.org/t/review-se-0023-api-design-guidelines/1162))
* [SE-0006 Apply API Guidelines to the Standard Library](0006-apply-api-guidelines-to-the-standard-library.md)
  ([Review](https://forums.swift.org/t/review-se-0006-apply-api-guidelines-to-the-standard-library/1163))
* [SE-0005 Better Translation of Objective-C APIs Into Swift](0005-objective-c-name-translation.md)
  ([Review](https://forums.swift.org/t/review-se-0005-better-translation-of-objective-c-apis-into-swift/1164))

These reviews are running concurrently because they interact strongly
(e.g., an API change in the standard library will correspond to a
particular guideline, or an importer rule implements a particular
guideline, etc.). Because of these interactions, and to keep
discussion manageable, we ask that you:

* **Please get a basic understanding of all three documents** before
  posting review commentary
* **Please post your review of each individual document in response to
  its review announcement**. It's okay (and encouraged) to make
  cross-references between the documents in your review where it helps
  you make a point.

## Introduction

This proposal describes how we can improve Swift's "Clang Importer", which is responsible for mapping C and Objective-C APIs into Swift, to translate the names of Objective-C functions, types, methods, properties, etc. into names that more closely align with the [Swift API Design Guidelines][api-design-guidelines] being developed as part of Swift 3. Our approach focuses on the differences between the Objective-C [Coding Guidelines for Cocoa][objc-cocoa-guidelines] and the Swift API Design Guidelines, using some simple linguistic analysis to aid the automatic translation from Objective-C names to more "Swifty" names.

The results of this transformation can be seen in the [Swift 3 API Guidelines Review](https://github.com/apple/swift-3-api-guidelines-review) repository, which contains Swift projections of Objective-C APIs in Swift 2 ([`swift-2` branch](https://github.com/apple/swift-3-api-guidelines-review/tree/swift-2)) and Swift 3 ([`swift-3` branch](https://github.com/apple/swift-3-api-guidelines-review/tree/swift-3)) along with partially-migrated sample code. One can also see the overall changes by [comparing the two branches](https://github.com/apple/swift-3-api-guidelines-review/compare/swift-2...swift-3).

## Motivation

The Objective-C [Coding Guidelines for Cocoa][objc-cocoa-guidelines]
provide a framework for creating clear, consistent APIs in
Objective-C, where they work extraordinarily well. However, Swift is a
different language: in particular, it is strongly typed and provides
type inference, generics, and overloading. As a result, Objective-C
APIs that feel right in Objective-C can feel wordy when used in
Swift. For example:

```swift
let content = listItemView.text.stringByTrimmingCharactersInSet(
   NSCharacterSet.whitespaceAndNewlineCharacterSet())
```

The APIs used here follow the Objective-C guidelines. A more "Swifty"
version of the same code might instead look like this:

```swift
let content = listItemView.text.trimming(.whitespaceAndNewlines)
```

The latter example more closely adheres to the [Swift API Design
Guidelines][api-design-guidelines], in particular, omitting "needless"
words that restate the types already enforced by the compiler (view,
string, character set, etc.). The goal of this proposal is to make
imported Objective-C feel more "Swifty", providing a more fluid
experience for Swift programmers using Objective-C APIs.

The solution in this proposal applies equally to the Objective-C
frameworks (e.g., all of Cocoa and Cocoa Touch) and any Objective-C
APIs that are available to Swift in mix-and-match projects. Note that
the [Swift core libraries][core-libraries]
reimplement the APIs of Objective-C frameworks, so any API changes to
those frameworks (Foundation, XCTest, etc.) will be reflected in the
Swift 3 implementations of the core libraries.

## Proposed solution

The proposed solution involves identifying the differences between the
Objective-C [Coding Guidelines for Cocoa][objc-cocoa-guidelines] and
the [Swift API Design Guidelines][api-design-guidelines] to build a
set of transformations that map from the former to the latter based on
the guidelines themselves and other observed conventions in
Objective-C. This is an extension of other heuristics in the Clang
importer that translate names, e.g., the mapping of global enum
constants into Swift's cases (which strips common prefixes from the
enum constant names) and the mapping from Objective-C factory methods
(e.g., `+[NSNumber numberWithBool:]`) to Swift initializers
(`NSNumber(bool: true)`).

The heuristics described in this proposal will require iteration,
tuning, and experimentation across a large body of Objective-C APIs to
get right. Moreover, it will not be perfect: some APIs will
undoubtedly end up being less clear in Swift following this
translation than they had been before. Therefore, the goal is to make
the vast majority of imported Objective-C APIs feel more "Swifty", and
allow the authors of Objective-C APIs that end up being less clear to
address those problems on a per-API basis via annotation within the
Objective-C headers.

The proposed solution involves several related changes to the Clang importer:

1. **Generalize the applicability of the `swift_name` attribute**: The
Clang `swift_name` attribute currently allows limited renaming of enum
cases and factory methods. It should be generalized to allow arbitrary
renaming of any C or Objective-C entity when it is imported into
Swift, allowing authors of C or Objective-C APIs more fine-grained
control over the process.

2. **Prune redundant type names**: The Objective-C Coding Guidelines
   for Cocoa require that the method describe each argument. When
   those descriptions restate the type of the corresponding parameter,
   the name conflicts with the
   [omit needless words](https://swift.org/documentation/api-design-guidelines#omit-needless-words)
   guideline for Swift APIs. Therefore, we prune these type names
   during import.

3. **Add default arguments**: In cases where the Objective-C API strongly hints at the need for a default argument, infer the default argument when importing the API. For example, an option-set parameter can be defaulted to `[]`.

4. **Add first argument labels**: If the first parameter of a method
   is defaulted,
   [it should have an argument label](https://swift.org/documentation/api-design-guidelines#first-argument-label). Determine
   a first argument label for that method.

5. **Prepend "is" to Boolean properties**:
   [Boolean properties should read as assertions on the receiver](https://swift.org/documentation/api-design-guidelines#boolean-assertions),
   but the Objective-C Coding Guidelines for Cocoa
   [prohibit the use of "is" on properties](https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/CodingGuidelines/Articles/NamingIvarsAndTypes.html#//apple_ref/doc/uid/20001284-BAJGIIJE). Import
   such properties with "is" prepended.

6. **Lowercase values**: The Swift API Design Guidelines have non-type
declarations lowercased. Lowercase non-prefixed values whenever they
are imported, including enumerators (whether they end up in Swift as
enum cases or option sets) and any other properties/functions (e.g., a
property named `URLHandler` will be lowercased to `urlHandler`).

7. **Adopt Comparable to classes that implement** `compare(_:) -> NSComparisonResult`: The objective-c classes that implement compare all have declared a capability of being compared in an ordered manner. `Comparable` formalizes this declaration into an implementable operator by the import process.

To get a sense of what these transformations do, consider a portion of
the imported `UIBezierPath` API in Swift 2:

```swift
class UIBezierPath : NSObject, NSCopying, NSCoding {
  convenience init(ovalInRect: CGRect)
  func moveToPoint(_: CGPoint)
  func addLineToPoint(_: CGPoint)
  func addCurveToPoint(_: CGPoint, controlPoint1: CGPoint, controlPoint2: CGPoint)
  func addQuadCurveToPoint(_: CGPoint, controlPoint: CGPoint)
  func appendPath(_: UIBezierPath)
  func bezierPathByReversingPath() -> UIBezierPath
  func applyTransform(_: CGAffineTransform)
  var empty: Bool { get }
  func containsPoint(_: CGPoint) -> Bool
  func fillWithBlendMode(_: CGBlendMode, alpha: CGFloat)
  func strokeWithBlendMode(_: CGBlendMode, alpha: CGFloat)
  func copyWithZone(_: NSZone) -> AnyObject
  func encodeWithCoder(_: NSCoder)
}
```

And the same API imported under our current, experimental implementation of this proposal:

```swift
class UIBezierPath : NSObject, NSCopying, NSCoding {
  convenience init(ovalIn rect: CGRect)
  func move(to point: CGPoint)
  func addLine(to point: CGPoint)
  func addCurve(to endPoint: CGPoint, controlPoint1 controlPoint1: CGPoint, controlPoint2 controlPoint2: CGPoint)
  func addQuadCurve(to endPoint: CGPoint, controlPoint controlPoint: CGPoint)
  func append(_ bezierPath: UIBezierPath)
  func reversing() -> UIBezierPath
  func apply(_ transform: CGAffineTransform)
  var isEmpty: Bool { get }
  func contains(_ point: CGPoint) -> Bool
  func fill(_ blendMode: CGBlendMode, alpha alpha: CGFloat)
  func stroke(_ blendMode: CGBlendMode, alpha alpha: CGFloat)
  func copy(with zone: NSZone = nil) -> AnyObject
  func encode(with aCoder: NSCoder)
}
```

In the latter case, a number of words that restated type information
in the original APIs have been pruned. The result is closer to
following the Swift API Design Guidelines. For example, this shows
that Swift developers can now copy any object conforming to the
NSCopying with a simple call to `foo.copy()` instead of calling
`foo.copyWithZone(nil)`.

## Implementation Experience

An experimental implementation of this proposal is available in the
main Swift repository. There are a set of compiler flags that one can
use to see the results of applying this proposal to imported
Objective-C APIs (e.g., via the script in
`utils/omit-needless-words.py`) and to Swift code itself. The flags
are:

* `-enable-omit-needless-words`: this flag enables most of the changes
  to the Clang importer (bullets 1, 2, 4, and 5 in the prior
  section). It is currently suitable only for printing the Swift
  interface to Objective-C modules (e.g., via `swift-ide-test`) in the
  Swift master branch and [Swift 2.2 branch][swift-2_2-branch], and is enabled on the [Swift 3 API Guidelines branch][swift-3-api-guidelines-branch].

* `-enable-infer-default-arguments`: this flag enables inference of
  default arguments in the Clang importer (bullet 3 in the prior
  section).

* `-swift3-migration`: only available on the [Swift 2.2
  branch][swift-2_2-branch], this flag performs basic migration from
  Swift 2 names to the Swift 3 names via Fix-Its. Tied together with
  other compiler flags (e.g., `-fixit-code`, `-fixit-all`) and a
  script to collect and apply Fix-Its (in
  `utils/apply-fixit-edits.py`), this flag provides a rudimentary
  migrator that lets us see how Swift code would look under the
  proposed changes, updating both declarations and use sites.

To actually get the "Swift 3 experience" of compiling code using these
names, one can use the [Swift 3 API Guidelines
branch][swift-3-api-guidelines-branch], which enables these features
by default along with the changes to the standard library.

## Detailed design

This section details the experimental implementation of rules 2-5 in prose. The actual implementation is available in the Swift source tree, mostly in the `omitNeedlessWords` functions of [lib/Basic/StringExtras.cpp](https://github.com/apple/swift/blob/master/lib/Basic/StringExtras.cpp).

The descriptions in this section are described in terms of the incoming Objective-C API. For example, Objective-C method names are "selectors", e.g., `startWithQueue:completionHandler:` is a selector with two selector pieces, `startWithQueue` and `completionHandler`. A direct mapping of this name into Swift would produce `startWithQueue(_:completionHandler:)`.


### Prune redundant type names

Objective-C API names often contain names of parameter and/or result
types that would be omitted in a Swift API. The following rules are
designed to identify and remove these
words. [[Omit Needless Words](https://swift.org/documentation/api-design-guidelines#omit-needless-words)]

#### Identifying type names

The matching process described below searches in a selector piece for
a suffix of a string called the **type name**, which is defined as follows:

* For most Objective-C types, the *type name* is the name under which
  Swift imports the type, ignoring nullability. For example,

  |Objective-C type       | *Type Name*                                |
  |-----------------------|--------------------------------------------|
  |`float`                |`Float`                                     |
  |`nullable NSString`    |`String`                                    |
  |`UIDocument`           |`UIDocument`                                |
  |`nullable UIDocument`  |`UIDocument`                                |
  |`NSInteger`            |`NSInteger`                                 |
  |`NSUInteger`           |`NSUInteger`                                |
  |`CGFloat`              |`CGFloat`                                   |

* When the Objective-C type is a block, the *type name* is "`Block`."

* When the Objective-C type is a pointer- or reference-to-function,
  the *type name* is "`Function`."

* When the Objective-C type is a typedef other than `NSInteger`,
  `NSUInteger`, or `CGFloat` (which follow the first rule above), the
  *type name* is that of the underlying type. For example, when the
  Objective-C type is `UILayoutPriority`, which is a typedef for
  `float`, we try to match the string
  "`Float`". [[Compensate for Weak Type Information](https://swift.org/documentation/api-design-guidelines#weak-type-information)]

#### Matching

In order to prune a redundant type name from a selector piece, we
need to match a substring of the selector that identifies the type.  

A couple of basic rules govern all matches:

* **Matches begin and end at word boundaries** in both type names and
  selector pieces.  Word boundaries occur at the beginning and end of
  a string, and before every capital letter.

  Treating every capital letter as the beginning of a word allows us
  to match uppercased acronyms without maintaining a special lists of
  acronyms or prefixes:

  <pre>
  func documentFor<b>URL</b>(_: NS<b>URL</b>) -> NSDocument?
  </pre>

  while preventing partial-word mismatches:

  <pre>
  var thumbnailPre<b>view</b> : UI<b>View</b>  // not matched
  </pre>

* **Matched text extends to the end of the type name**. Because we
  accept a match for *any suffix* of the type name, this code:

  <pre>
  func constraintEqualTo<b>Anchor</b>(anchor: NSLayout<b>Anchor</b>) -&gt; NSLayoutConstraint?
  </pre>

  can be pruned as follows:

  <pre>
  func constraintEqualTo(anchor: NSLayoutAnchor) -&gt; NSLayoutConstraint?
  </pre>

  Conveniently, matching by suffix also means that module prefixes
  such as `NS` do not prevent matching or pruning.

Matches are a sequence of one or more of the following:

* **Basic matches**

  * Any substring of the selector piece matches an identical
    substring of the type name, e.g., `String` in `appendString`
    matches `String` in `NSString`:

    <pre>
    func append<b>String</b>(_: NS<b>String</b>)
    </pre>

  * `Index` in the selector piece matches `Int` in the type name:

    <pre>
    func characterAt<b>Index</b>(_: <b>Int</b>) -> unichar
    </pre>

* **Collection matches**

  * `Indexes` or `Indices` in the selector piece matches `IndexSet` in
  the type name:

    <pre>
    func removeObjectsAt<b>Indexes</b>(_: NS<b>IndexSet</b>)
    </pre>

  * A plural noun in the selector piece matches a collection type name
    if the noun's singular form matches the name of the collection's
    element type:

    <pre>
    func arrange<b>Objects</b>(_: <b>[</b>Any<b>Object]</b>) -> [AnyObject]
    </pre>

* **Special suffix matches**

  * The empty string in the selector piece matches `Type` or `_t` in the type name:

    <pre>
    func writableTypesFor<b>SaveOperation</b>(_: NS<b>SaveOperation</b><i>Type</i>) -> [String]
    func objectFor<b>Key</b>(_: <b>Key</b><i>Type</i>) -> AnyObject
    func startWith<b>Queue</b>(_: dispatch_<b>queue</b><i>_t</i>, completionHandler: MKMapSnapshotCompletionhandler)
    </pre>

  * The empty string in the selector piece matches *one or more digits
    followed by "D"* in the type name:

    <pre>
    func pointFor<b>Coordinate</b>(_: CLLocation<b>Coordinate</b><i>2D</i>) -> NSPoint
    </pre>

In the examples above, the italic text is effectively skipped, so the
bold part of the selector piece can be matched and pruned.

#### Pruning Restrictions

The following restrictions govern the pruning steps listed in the
next section.  If any step would violate one of these rules, it is
skipped.

* **Never make a selector piece entirely empty**.

* **Never transform the first selector piece into a Swift keyword**,
  to avoid forcing the user to escape it with backticks. In Swift, the
  first Objective-C selector piece becomes:

    * the base name of a method
    * or the full name of a property 

  neither of which can match a Swift keyword without forcing the
  user to write backticks.  For example,

  <pre>
  extension NSParagraphStyle {
  &nbsp;&nbsp;class func default<b>ParagraphStyle</b>() -> NS<b>ParagraphStyle</b>
  }
  let defaultStyle = NSParagraphStyle.<b>default</b>ParagraphStyle()  // OK
  </pre>

  would become:

  <pre>
  extension NSParagraphStyle {
  &nbsp;&nbsp;class func <b>`default`</b>() -> NSParagraphStyle
  }
  let defaultStyle = NSParagraphStyle.<b>`default`</b>()              // Awkward
  </pre>

  By contrast, later selector pieces become argument labels, which
  are allowed to match Swift keywords without requiring backticks:

  <pre>
  receiver.handle(someMessage, <b>for</b>: somebody)  // OK
  </pre>

* **Never transform a name into "get", "set", "with", "for", or
  "using"**, just to avoid creating absurdly vacuous names.

* **Never prune a suffix from a parameter introducer unless the suffix
  is immediately preceded by a preposition, verb, or gerund**.


  This heuristic has the effect of preventing us from breaking up
  sequences of nouns that refer to a parameter.  Dropping just the
  suffix of a noun phrase tends to imply something unintended about
  the parameter that follows.  For example,

  <pre>
  func setText<b>Color</b>(_: UI<b>Color</b>)
  ...
  button.<b>setTextColor</b>(.red())  <b>// clear</b>
  </pre>

  If we were to drop `Color`, leaving just `Text`, call sites 
  would become confusing:

  <pre>
  func setText(_: UIColor)
  ...
  button.<b>setText</b>(.red())      <b>// appears to be setting the text!</b>
  </pre>

  Note: We don't maintain a list of nouns, but if we did, this
  rule could be more simply phrased as "don't prune a suffix
  leaving a trailing noun before a parameter".

* **Never prune a suffix from the base name of a method that matches a property of the enclosing class**: 

  This heuristic has the effect of preventing us from producing
  too-generic names for methods that conceptually modify a property
  of the class.

  <pre>
  var <b>gestureRecognizers</b>: [UIGestureRecognizer]
  func add<b>GestureRecognizer</b>(_: UI<b>GestureRecognizer</b>)
  </pre>

  If we were to drop `GestureRecognizer`, leaving just `add`, we end
  up with a method that conceptually modifies the
  `gestureRecognizers` property but uses an overly generic name to
  do so:

  <pre>
  var gestureRecognizers: [UIGestureRecognizer]
  func add(_: UIGestureRecognizer) <b>// should indicate that we're adding to the property</b>
  </pre>

#### Pruning Steps

The following pruning steps are performed in the order
shown:

1. **Prune the result type from the head of type-preserving
   transforms**.  Specifically, when

   * the receiver type is the same as the result type
   * and the type name is matched at the head of the first selector piece
   * and the match is followed by a preposition

   then prune the match.

   You can think of the affected operations as properties or
   non-mutating methods that produce a transformed version of the
   receiver.  For example:

   <pre>
   extension NS<b>Color</b> {
   &nbsp;&nbsp;func <b>color</b><i>With</i>AlphaComponent(_: CGFloat) -> NS<b>Color</b>
   }
   let translucentForeground = <b>foregroundColor.color</b><i>With</i>AlphaComponent(0.5)
   </pre>

   becomes:

   <pre>
   extension NS<b>Color</b> {
   &nbsp;&nbsp;func <i>with</i>AlphaComponent(_: CGFloat) -> NS<b>Color</b>
   }
   let translucentForeground = <b>foregroundColor</b>.<i>with</i>AlphaComponent(0.5)
   </pre>

2. **Prune an additional hanging "By"**. Specifically, if

   * anything was pruned in step 1
   * and the remaining selector piece begins with "`By`" *followed by a gerund*,

   then prune the initial "`By`" as well.
   
   This heuristic allows us to arrive at usage of the form `a =
   b.frobnicating(c)`.  For example:

   <pre>
   extension NSString {
   &nbsp;&nbsp;func string<b>By</b><i>Applying</i>Transform(_: NSString, reverse: Bool) -> NSString?
   }
   let sanitizedInput = rawInput.<b>stringByApplyingTransform</b>(NSStringTransformToXMLHex, reverse: false)
   </pre>

   becomes:

   <pre>
   extension NSString {
   &nbsp;&nbsp;func applyingTransform(_: NSString, reverse: Bool) -> NString?
   }
   let sanitizedInput = rawInput.<b>applyingTransform</b>(NSStringTransformToXMLHex, reverse: false)
   </pre>

3. **Prune a match for any type name in the signature from the tail of
   the preceding selector piece**. Specifically,

   |From the tail of:                               |Prune a match for:              |
   |------------------------------------------------|--------------------------------|
   |a selector piece that introduces a parameter    |the parameter type name         |
   |the name of a property                          |the property type name          |
   |the name of a zero-argument method              |the return type name            |
       
   For example,

   <pre>
   extension NSDocumentController {
   &nbsp;&nbsp;func documentFor<b>URL</b>(_ url: NS<b>URL</b>) -> NSDocument? // parameter introducer
   }
   extension NSManagedObjectContext {
   &nbsp;&nbsp;var parent<b>Context</b>: NSManagedObject<b>Context</b>?       // property
   }
   extension UIColor {
   &nbsp;&nbsp;class func darkGray<b>Color</b>() -> UI<b>Color</b>            // zero-argument method
   }
   ...
   myDocument = self.documentFor<b>URL</b>(locationOfFile)
   if self.managedObjectContext.parent<b>Context</b> != changedContext { return }
   foregroundColor = .darkGray<b>Color</b>()
   </pre>

   becomes:

   <pre>
   extension NSDocumentController {
   &nbsp;&nbsp;func documentFor(_ url: NSURL) -> NSDocument?
   }
   extension NSManagedObjectContext {
   &nbsp;&nbsp;var parent : NSManagedObjectContext?
   }
   extension UIColor {
   &nbsp;&nbsp;class func darkGray() -> UIColor
   }
   ...
   myDocument = self.<b>documentFor</b>(locationOfFile)
   if self.managedObjectContext.<b>parent</b> != changedContext { return }
   foregroundColor = .<b>darkGray</b>()
   </pre>

3. **Prune a match for the enclosing type from the base name of a method so long as the match starts after a verb**. For example,

   <pre>
   extension UI<b>ViewController</b> {
   &nbsp;&nbsp;func dismiss<b>ViewController</b>Animated(flag: Bool, completion: (() -> Void)? = nil)
   }
   </pre>

   becomes:

   <pre>
   extension UIViewController {
   &nbsp;&nbsp;func dismissAnimated(flag: Bool, completion: (() -> Void)? = nil)
   }
   </pre>

##### Why Does Order Matter?

Some steps below prune matches from the head of the first selector
piece, and some prune from the tail.  When [pruning restrictions](#pruning-restrictions)
prevent both the head and tail from being pruned, prioritizing
head-pruning steps can keep method families together.  For example,
in NSFontDescriptor:

```swift
func fontDescriptorWithSymbolicTraits(_: NSFontSymbolicTraits) -> NSFontDescriptor
func fontDescriptorWithSize(_: CGFloat) -> UIFontDescriptor
func fontDescriptorWithMatrix(_: CGAffineTransform) ->  UIFontDescriptor
...
```

becomes:

<pre>
func <b>with</b>SymbolicTraits(_: UIFontDescriptorSymbolicTraits) ->  UIFontDescriptor
func <b>with</b>Size(_: CGFloat) -> UIFontDescriptor
func <b>with</b>Matrix(_: CGAffineTransform) -> UIFontDescriptor
...
</pre>

If we instead began by pruning `SymbolicTraits` from the tail of
the first method name, the prohibition against creating absurdly
vacuous names would prevent us from pruning "`fontDescriptorWith`"
down to "`with`", resulting in:

<pre>
func <b>fontDescriptorWith</b>(_: NSFontSymbolicTraits) -> NSFontDescriptor // inconsistent
func withSize(_: CGFloat) -> UIFontDescriptor
func withMatrix(_: CGAffineTransform) -> UIFontDescriptor
...
</pre>


#### Add Default Arguments

For any method that is not a single-parameter setter, default
arguments are added to parameters in the following cases:

* **Nullable trailing closure parameters** are given a default value of `nil`.

* **Nullable NSZone parameters** are given a default value of `nil`. Zones are essentially unused in Swift and should always be ``nil``.

* **Option set types** whose type name contain the word "Options" are given a default value of `[]` (the empty option set).

* **NSDictionary parameters** with names that involve "options", "attributes", or "info" are given a default value of `[:]`. 

Together, these heuristics allow code like:

<pre>
rootViewController.presentViewController(alert, animated: true<b>, completion: nil</b>)
UIView.animateWithDuration(
  0.2, delay: 0.0, <b>options: [],</b> animations: { self.logo.alpha = 0.0 }) { 
    _ in self.logo.hidden = true 
}
</pre>

to become:

```swift
rootViewController.present(alert, animated: true)
UIView.animateWithDuration(
  0.2, delay: 0.0, animations: { self.logo.alpha = 0.0 }) { _ in self.logo.hidden = true }
```

#### Add First Argument Labels

If the first selector piece contains a preposition, **split the first
selector piece at the last preposition**, turning everything
starting with the last preposition into a *required* label for the
first argument.

As well as creating first argument label for a significant number of
APIs, this heuristic eliminates words that refer only to the first
argument from call sites where the argument's default value is
used. For example, instead of:

<pre>
extension UIBezierPath {
  func enumerateObjects<b>With</b>(_: NSEnumerationOptions <b>= []</b>, using: (AnyObject, UnsafeMutablePointer<ObjCBool>) -> Void)
}

array.enumerateObjects<b>With</b>(.Reverse) { // OK
 // ..
}

array.enumerateObjects<b>With</b>() {         // ?? With what?
 // ..
}
</pre>

we get:

<pre>
extension NSArray {
  func enumerateObjects(<b>options</b> _: NSEnumerationOptions <b>= []</b>, using: (AnyObject, UnsafeMutablePointer<ObjCBool>) -> Void)
}

array.enumerateObjects(<b>options:</b> .Reverse) { // OK
 // ..
}

array.enumerateObjects() {               // OK
 // ..
}
</pre>

#### Use getter names for Boolean Properties

**For Boolean properties, use the name of the getter as the property
  name in Swift*. For example:

```swift
@interface NSBezierPath : NSObject
@property (readonly,getter=isEmpty) BOOL empty;
```

will become

<pre>
extension NSBezierPath {
  var <b>isEmpty</b>: Bool
}

if path.<b>isEmpty</b> { ... }
</pre>

### Conformance of implementers of compare method

Currently, in comparing protocols, for example developers usually have
to extend `NSDate` to make it to conform to `Comparable`, or use 
`compare(_:) -> NSComparisonResult` method of `NSDate` directly. In
this case Using comparison operators on `NSDate`s will make the code 
more readable, such as `someDate < today`, rather than 
`someDate.compare(today) == .OrderedAscending`. Since the import process
can determine if a class implements the objective-c method for 
comparison all classes that implement this method will then be imported
as adopting `Comparable`. 

A survey of Foundation classes reveals not just NSDate but a few
other classes that would be affected by this change.

```swift
func compare(other: NSDate) -> NSComparisonResult
func compare(decimalNumber: NSNumber) -> NSComparisonResult
func compare(otherObject: NSIndexPath) -> NSComparisonResult
func compare(string: String) -> NSComparisonResult
func compare(otherNumber: NSNumber) -> NSComparisonResult
```

## Impact on existing code

The proposed changes are massively source-breaking for Swift code that
makes use of Objective-C frameworks, and will require a migrator to
translate Swift 2 code into Swift 3 code. The `-swift3-migration`
flag described in the [Implementation
Experience](#implementation-experience) section can provide the basics
for such a migrator. Additionally, the compiler needs to provide good
error messages (with Fix-Its) for Swift code that refers to the old
(pre-transformed) Objective-C names, which could be achieved with some
combination of the Fix-Its described previously and a secondary name
lookup mechanism retaining the old names.

## Acknowledgments

The automatic translation described in this proposal has been
developed as part of the effort to produce the [Swift API Design
Guidelines][api-design-guidelines] with Dmitri Hrybenko, Ted Kremenek,
Chris Lattner, Alex Migicovsky, Max Moiseev, Ali Ozer, and Tony Parker.

The addendum of comparable was originally proposed to the [core-libraries]
mailing list by [Chris Amanse](https://github.com/chrisamanse) and modified
to fit to this proposal after review by Philippe Hausler.

[objc-cocoa-guidelines]: https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/CodingGuidelines/CodingGuidelines.html  "Coding Guidelines for Cocoa"
[api-design-guidelines]: https://swift.org/documentation/api-design-guidelines "API Design Guidelines"
[core-libraries]: https://swift.org/core-libraries/  "Swift Core Libraries"
[swift-3-api-guidelines-branch]: https://github.com/apple/swift/tree/swift-3-api-guidelines  "Swift 3 API Guidelines branch"
[swift-2_2-branch]: https://github.com/apple/swift/tree/swift-2.2-branch  "Swift 2.2 branch"
