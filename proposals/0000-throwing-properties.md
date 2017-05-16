# Throwing Properties and Subscripts

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Brent Royal-Gordon](https://github.com/brentdax)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Functions, methods, and initializers can be marked `throws` to indicate 
that they can fail by throwing an error, but properties and subscripts 
cannot. This proposal extends properties and subscripts to support 
`throws` and `rethrows` accessors, and also specifies logic for 
bridging these accessors to and from Objective-C.

Swift-evolution threads: [Proposal: Allow Getters and Setters to Throw](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001165.html), [[Draft] Throwing Properties and Subscripts](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160314/012602.html)

## Motivation

Sometimes, something that is genuinely getter- or setter-like needs to 
be able to throw an error. This is particularly common with properties
which access an external resource which may not be in the right state 
to return the data:

```swift
var avatar: UIImage {
    get {
        let data = /* can't */ try NSData(contentsOfURL: avatarURL)
        guard image = UIImage(data: data) else {
            /* can't */ throw UserError.corruptedImage
        }
        return image
    }
}
```

Or which convert between formats:

```swift
var json: [String: JSONValue] {
    get {
        return [
            "username": username,
            "posts": /* can't */ try posts.map { $0.json }
        ]
    }
    set {
        guard let newUsername = newValue["username"] as? String else {
            /* can't */ throw UserError.invalidUserField("username")
        }
        guard let newPostsJSON = newValue["posts"] as? [Post.JSONRepresentation] else {
            /* can't */ throw UserError.invalidUserField("posts")
        }
        
        posts = /* can't */ try newPostsJSON.map { Post(json: $0) }
        username = newUsername
    }
}
```

The current best solution to this problem is to write a method instead 
of a property. This can lead to unnatural API designs; one extreme 
example from the frameworks, `AVAudioSession`, has no less than ten 
mismatched property/setter method pairs:

```swift
var category: String { get }
func setCategory(_ category: String) throws

var mode: String { get }
func setMode(_ mode: String) throws

var inputGain: Float { get }
func setInputGain(_ gain: Float) throws

var preferredSampleRate: Double { get }
func setPreferredSampleRate(_ sampleRate: Double) throws

var preferredIOBufferDuration: NSTimeInterval { get }
func setPreferredIOBufferDuration(_ duration: NSTimeInterval) throws

var preferredInputNumberOfChannels: Int { get }
func setPreferredInputNumberOfChannels(_ count: Int) throws

var preferredOutputNumberOfChannels: Int { get }
func setPreferredOutputNumberOfChannels(_ count: Int) throws

var preferredInput: AVAudioSessionPortDescription? { get }
func setPreferredInput(_ inPort: AVAudioSessionPortDescription?) throws

var inputDataSource: AVAudioSessionDataSourceDescription? { get }
func setInputDataSource(_ dataSource: AVAudioSessionDataSourceDescription?) throws

var outputDataSource: AVAudioSessionDataSourceDescription? { get }
func setOutputDataSource(_ dataSource: AVAudioSessionDataSourceDescription?) throws
```

While most classes aren't nearly this bad, you see the same problem 
elsewhere in the frameworks. The Mac-only `CoreWLAN` framework has 
similar mismatched property/setter method pairs (though it also has 
other bridging issues; I suspect it's too obscure to have been audited 
yet):

```swift
func wlanChannel() -> CWChannel!
func setWLANChannel(_ channel: CWChannel!, error error: NSErrorPointer) -> Bool

func powerOn() -> Bool
func setPower(_ power: Bool, error error: NSErrorPointer) -> Bool
```

When the getter can throw, it gets even worse. `NSURL` has an awkward 
pair of methods to get "resource values" which would be better 
expressed as a throwing read-write subscript:

```swift
func getResourceValue(_ value: AutoreleasingUnsafeMutablePointer<AnyObject?>, forKey key: String) throws
func setResourceValue(_ value: AnyObject?, forKey key: String) throws
```

## Proposed solution

Swift can handle these cases better by allowing getters and setters to
throw.

### Declaring throwing accessors

You can mark a computed property accessor as throwing by putting 
`throws` after the `get` or `set` keyword:

```swift
var property: Int {
    get throws { ... }
    set throws { ... }
}

subscript(index: Int) -> Bool {
    get throws { ... }
    set throws { ... }
}
```

The throwing behavior of the getter and setter are completely 
independent; a throwing getter can be paired with a non-throwing 
setter, or vice versa.

```swift
var property: Int {
    get throws { ... }
    set { ... }
}

subscript(index: Int) -> Bool {
    get { ... }
    set throws { ... }
}
```

A protocol (or, if added later, an abstract class) can specify the 
throwing behavior of properties and subscripts it requires:

```swift
protocol MyProtocol {
    var property: Int { get throws set throws }
    subscript(index: Int) -> Bool { get throws set throws }
}
```

### Using throwing accessors

Just as you would with a throwing function or initializer, any 
expression which invokes a throwing accessor must be marked with the 
`try` keyword. For instance, with this type:

```swift
struct ThrowingDemo {
    var noThrow: Int { get {...} set {...} }
    var readThrow: Int { get throws {...} set {...} }
    var writeThrow: Int { get {...} set throws {...} }
    var bothThrow: Int { get throws {...} set throws {...} }
}
var demo = ThrowingDemo()
```

The following uses require a `try`:

```swift
_ = try demo.readThrow
try demo.writeThrow = 1
_ = try demo.bothThrow
try demo.bothThrow = 1
```

But these do not:

```swift
_ = demo.noThrow
demo.noThrow = 1
demo.readThrow = 1
_ = demo.writeThrow
```

Uses which simultaneously read and write, such as `inout` parameters, 
in-place operators, and use of `mutating` members, require a `try` if 
either accessor throws.

```swift
demo.noThrow += 1
try demo.readThrow += 1
try demo.writeThrow += 1
try demo.bothThrow += 1
```

### Objective-C bridging

Throwing accessors in Swift are represented in Objective-C as methods 
with certain signatures. These transformations are applied to both 
protocols and classes.

Properties are bridged by default with names generated from the 
property name. You can disable bridging by marking the accessor with 
`@nonobjc`, or change the name with `@objc(name)`.

Subscripts are not bridged by default. You can explicitly ask for a 
Swift subscript accessor to be exported by specifying a name with the 
`@objc(name)` format. A plain `@objc` is not permitted.

If If [SE-0044 Import as member](https://github.com/apple/swift-evolution/blob/master/proposals/0044-import-as-member.md) 
is accepted, the `swift_name` property should be able to control how 
methods (and functions) with appropriate signatures will be imported to 
Swift as throwing property accessors. If it is extended to support 
subscripts, this support may be extended to throwing subscript 
accessors, too.

#### Bridging of throwing setters

A throwing setter for a property named `foo` of type `T` is represented 
in Objective-C as:

```objc
- (BOOL)setFoo:(T)value error:(NSError**)error;
```

A throwing setter for a subscript with an index of type `I` is 
represented in Objective-C as a method of the form:

```objc
- (BOOL)setFoo:(T)value atIndex:(I)index error:(NSError**)error;
```

When a non-throwing setter is paired with a throwing getter, it is 
represented as a method like the above, but with a `void` return and no 
`error` parameter.

#### Bridging of throwing getters

A throwing getter for a property named `foo` of type `T` is represented 
in Objective-C in one of two ways. If `T` is not optional, but its 
Objective-C equivalent is nullable, it is represented as:

```objc
- (nullable T)foo:(NSError**)error;
```

Otherwise, it is represented as:

```objc
- (BOOL)getFoo:(appropriate_nullability T*)outValue error:(NSError**)error;
```

A throwing setter for a subscript with an index of type `I` is 
represented in Objective-C analogously:

```objc
- (nullable T)fooAtIndex:(I)index error:(NSError**)error;
- (BOOL)getFoo:(appropriate_nullability T*)outValue atIndex:(I)index error:(NSError**)error;
```

When a non-throwing getter is paired with a throwing setter, it is 
represented as though there were no setter (i.e. as a readonly property 
or an Objective-C subscript method).

## Detailed design

### Subscripts with `rethrows`

`rethrows` is not supported on properties, but it is supported on 
subscripts. The rethrowing behavior depends only on the subscript's 
parameters, not the setter's `newValue`; that is, a particular 
subscript access can throw iff at least one of the functions inside the 
square brackets can throw.

### Throwing accessors and `inout` parameters

A throwing property or subscript access can be passed as an `inout` 
parameter. The call it is passed to must be marked with the `try` 
keyword.

To the call with the `inout` parameter, a throwing property or 
subscript is indistinguishable from a non-throwing one. To avoid 
unpredictable interactions between `inout` and throwing accessors, 
Swift will guarantee the getter is invoked once before the call and the 
setter zero or one times after the call. The compiler will not apply 
optimizations which might cause errors to be thrown in the middle of 
the function.

### Throwing requirement compatibility

An implementation can be "less" throwing than a requirement it is 
intended to satisfy. That is:

* A throwing accessor requirement can be fulfilled by a throwing, 
  rethrowing, or non-throwing accessor.
* A rethrowing accessor requirement can be fulfilled by a rethrowing 
  or non-throwing accessor.
* A non-throwing accessor requirement can be fulfilled only by a 
  non-throwing accessor.

These definitions apply to protocol (and abstract class) conformance, 
subclass overrides, and library resilience. (Note that last point: 
Swift must permit an accessor to be made less throwing without breaking 
binary compatibility.)

When overriding a throwing accessor, the override must explicitly state
the expected level of throwing behavior; omitting the keyword means the
accessor is non-throwing. That is, in this example, `Subclass.foo`'s
setter is not automatically `throws`:

```swift
class Superclass {
    var foo: Int {
        willSet throws { ... }
    }
}

class Subclass: Superclass {
    override var foo: Int {
        set { try super.foo = newValue }
        // Error: nonthrowing setter includes throwing statement
    }
}
```

### Implementation

#### Grammar changes

(This section is based on *The Swift Programming Language*'s grammar 
summary, not anything in the compiler source code.)

Grammar productions related to the `get` and `set` accessors:

> getter-clause -> *attributes(opt)* `get` *code-block*
> 
>‌ setter-clause -> *attributes(opt)* `set` *setter-name(opt)* *code-block*
>
> getter-keyword-clause -> *attributes(opt)* `get`
>
>‌ setter-keyword-clause -> *attributes(opt)* `set`

Will need to be changed to accommodate a `throws` or `rethrows` 
keyword:

> accessor-throwing-keyword -> `throws` | `rethrows`
> 
> getter-clause -> *attributes(opt)* `get` *accessor-throwing-keyword(opt)* *code-block*
> 
>‌ setter-clause -> *attributes(opt)* `set` *setter-name(opt)* *accessor-throwing-keyword(opt)* *code-block*
>
> getter-keyword-clause -> *attributes(opt)* `get` *accessor-throwing-keyword(opt)*
>
>‌ setter-keyword-clause -> *attributes(opt)* `set` *accessor-throwing-keyword(opt)*

`rethrows` would not be valid inside a property declaration, only a 
subscript declaration, but I think that discovering that issue during 
parsing would be too difficult.

#### Private use accessors and optimization

Swift uses a series of special implementation detail accessors to 
optimize property access. Most notably, the compiler synthesizes a 
`materializeForSet` accessor, which allows code to modify a value 
in-place instead of copying it, modifying it, and copying it back. 
Swift also has a number of compiler-private accessors like 
`unsafeAddressor` to provide faster access to certain variables 
and subscripts.

It is expected that throwing accessors, and particularly throwing 
setters, will often prevent the use of these optimizations. This will 
make them slower than non-throwing accessors, but will also make this 
proposal simpler to implement, as the various private use accessors 
Swift uses to optimize things won't need to support throwing 
immediately, if ever.

However, Swift *is* permitted to create and use these private use 
accessors with throwing properties, as long as the semantics when they 
are used match those when the plain, boring `get` and `set` accessors 
are used. For instance, consider a subscript which can throw, but the 
setter can only throw in situations where the getter would already have 
done so:

```swift
struct ThrowingRepeat<Element> {
    var element: Element
    let count: Int
    
    private func validateIndex(_ i: Int) throws {
        guard i < count else {
            throw ThrowingRepeat.Error.SubscriptOutOfRange
        }
    }
    
    subscript (i: Int) -> Element {
        get throws {
            try validateIndex(i)
            return element
        }
        set throws {
            try validateIndex(i)
            element = newValue
        }
    }
}
```

Because the setter can only throw under the exact same conditions as 
the getter (and those conditions won't change—`i` will be the same 
and `count` is constant), the compiler could choose to write a 
`materializeForSet` which allows `element` to be modified directly.

Moreover, these private use accessors are permitted to cheat slightly: 
if the compiler is certain that the setter would throw an error *after* 
the rvalue was evaluated, it may throw that error *before* it is 
evaluated. For instance, imagine if the above `subscript` had only 
called `validateIndex(_:)` in its setter. The compiler could write a 
`materializeForSet` which called `validateIndex(_:)`, even though this 
would cause the error check to be performed at the point where the code 
got the old value rather than at the point where it set the new value, 
thus throwing before the rvalue was evaluated instead of after.

(For a variety of reasons, these rules are unlikely to come into play 
in practice, but I felt it was important to define them explicitly.)

## Impact on existing code

Some APIs will be imported differently, breaking call sites. The Swift 
compiler will need to provide fix-it and migration support for these 
cases.

## Alternatives considered

### Omit throwing getters on properties

Joe Groff argued against including throwing getters. He suggested that 
[properties with throwing getters might be better modeled as methods](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160314/012616.html), 
noting that "[t]he standard library doesn't even use property syntax 
for things that might unconditionally fail due to programmer error."

I disagree with him on several grounds:

* If you represent throwing getters as methods, the only way to 
  associate a setter with the `foo` method is to write a `setFoo` 
  method. I find `setFoo` methods distasteful—a major purpose of this 
  proposal is to eliminate a class of them—so I see that as a step 
  backwards.

* I believe some of the use cases for throwing getters are indeed 
  compelling. For instance:
  
  * When an instance is backed by an external resource, such as a 
    database record, the most natural representation of the fields in 
    that record is a property. However, if there is some sort of I/O or 
    other error in the underlying layers, that error will need to be 
    communicated to the caller. A property with a throwing getter is the 
    most natural way to represent this situation.
    
  * When a protocol requires a piece of data which could reasonably be 
    either stored or computed, and the computation might discover an 
    error which would need to be communicated to the caller, a throwing 
    getter is the most convenient solution. Without throwing getters, you 
    would be forced to represent the data as either a non-throwing getter 
    (which would make it impossible to signal errors) or a throwing 
    method (which would inconvenience conforming types which use a stored 
    property). A concrete example:
    
    ```swift
    protocol JSONRepresentable {
        var json: JSONValue { get throws }
    }
    ```
  
* Even if the use cases for properties are not strong enough, I believe 
  the use cases for subscripts are. For instance, an XMLNode type with 
  a subscript which took an XPath query would need to be able to throw 
  if the query was syntactically invalid. It would be strange to 
  support throwing accessors on subscripts but not properties.
  
  (Similarly, if we eventually support lvalue functions, they will 
  presumably be able to throw.)
  
* If we omit throwing getters in an attempt to get people to represent 
  those operations as functions, many users will not respond to this 
  incentive as hoped. Instead, they will substitute less appropriate 
  error handling mechanisms, such as preconditions, encoding the error 
  in the getter's return value (by returning a `Result`, `Optional`, 
  `ImplicitlyUnwrappedOptional`, or sentinel value), or abusing C++ or 
  Objective-C exceptions. Each of these would undermine at least one of 
  Swift's goals to make error handling safe, explicit, checkable, and 
  convenient.
  
* I believe there is value in ensuring that all entities which can run 
  arbitrary code can be made to throw. As one example among many, this 
  might make it possible to add a sort of "generic rethrowing" facility 
  which would allow you to make a throwing variant of a normally 
  non-throwing protocol. See the "Future directions" section for 
  details.
  
* Ultimately, this objection is based in an opinion about where to draw 
  the already ill-defined line between computed properties and methods. 
  There is no implementation problem here; nor is the feature confusing, 
  hard to explain, or misleading. It is merely a question of when you 
  should use this feature instead of a similar one.
  
  That means it's basically a matter of style. Although Swift is an 
  opinionated language in many ways, in matters of pure style it 
  generally errs on the side of permitting developers to make their own 
  choices. (See, for instance, [the require `self` proposal](https://github.com/apple/swift-evolution/blob/master/proposals/0009-require-self-for-accessing-instance-members.md), 
  the [thread about removing semicolons](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/002421.html), 
  and [the thread about removing `default`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001422.html).)
  Some developers will not want to use throwing getters, but others 
  will. Let's allow everyone to write their code in whatever way they 
  think will best express their intent.

Joe also thought that permitting getters to throw might complicate a 
future lens feature (functions that can be used to read or write a 
particular property on an instance passed to it). If it needed to model 
all of the details of the accessors' throwing behavior, that might 
complicate the feature. Upon discussion, we agreed that such a feature 
could make both getting and setting throw if either of the underlying 
accessors threw.

While throwing getters are very closely connected to throwing setters, 
they are ultimately severable and could be proposed separately if 
they're highly controversial.

### Require setters to be at least as throwing as getters

We could require the setter to be at least as throwing as the getter, 
i.e., combinations like `get throws set` or `get throws set rethrows` 
would be illegal. This may simplify certain use sites.

The current rule is that you must use `try` if any of the accessors 
used for that access can throw. But it may be slightly tricky for 
users to figure out whether an expression uses only the setter or both 
the setter and getter. With a `get throws set` combination, the former 
cases would not require a `try`, but the latter would:
  
```swift
getThrows = value           // no try
try getThrows += value      // needs try
```

Moreover, my understanding (which may be incorrect) is that Swift 
sometimes makes counterintuitive accessor choices, fetching existing 
values even where the code does not obviously require it. If so, this 
might mean that the code either has to demand `try` keywords in 
unexpected locations or implicitly insert them, changing behavior.

While there are some minor use cases for `get throws set`, they're 
somewhat of a stretch, and we could probably do without them.

I have chosen the design with maximum flexibility, but other people 
might weigh these factors differently.

### Make `rethrows` setters throwing if `newValue` is throwing

`newValue` is sort of like a parameter to the setter, so it might 
technically be more consistent for `rethrows` to consider `newValue` 
when deciding if a particular invocation `throws` or not. However, I 
can't imagine a case where this would be appropriate behavior, and 
considering only the subscript parameters makes the getter and setter 
work better together.

### Permit `try` on `&foo` itself, rather than the call using it

As specified, if `foo` has a throwing accessor and you want to pass it 
to a function `bar` with an inout parameter, you have to write this:

```swift
try bar(&foo)
```

In theory, we could instead allow you to mark only the `&` operator, 
leaving the rest of the expression uncovered by the `try`:

```swift
bar(try &foo)
```

This would make the source of the potential error more obvious, but it 
might make the semantics less clear, because `try &foo` can throw 
*after* the call is finished in addition to *before*. I judge the 
latter issue to be more serious.

### Try to convert keyed getter/setter methods to subscripts

Swift could conceivably apply heuristics to discover Objective-C method 
pairs that can be expressed as subscripts. For instance, the `NSURL` 
method pair cited in the Motivation section:

```swift
func getResourceValue(_ value: AutoreleasingUnsafeMutablePointer<AnyObject?>, forKey key: String) throws
func setResourceValue(_ value: AnyObject?, forKey key: String) throws
```

Could be imported like this:

```swift
subscript (resourceValueFor key: String) -> AnyObject? {
    get throws
    set throws
}
```

There are several reasons not to do this:

* There is no established pattern for throwing subscripts in 
  Objective-C, so any we might establish would be mistake-prone.
* [SE-0044](https://github.com/apple/swift-evolution/blob/master/proposals/0044-import-as-member.md)
  does not currently include subscripts, so there is no proposal 
  pending which would allow the heuristic to be tweaked or the 
  import logic to be invoked manually. (This is arguably an oversight 
  in SE-0044.)
* Many such cases would benefit from a human looking at the design. In 
  the `NSURL` case, for instance, a human looking at the broader type 
  might prefer a design like this:

```swift
var resourceValues: ResourceValues { get } 

struct ResourceValues {
    subscript (key: String) -> AnyObject? {
        get throws { ... }
        set throws { ... }
    }
    
    func get(for keys: [String]) throws -> [String: AnyObject] { ... }
    func set(from dict: [String: AnyObject]) throws { ... }
    
    func removeCachedKeys() { ... }
    func removeCachedKey(_ key: String) { ... }
    func setTemporaryValue(_ value: AnyObject?, for key: String) { ... }
}
```

### Automatically export throwing subscript accessors to Objective-C

Throwing subscript accessors can only be exported by specifying a name 
using an `@objc` property. It might be nice to export them by default,
but Objective-C doesn't have an established pattern for throwing 
subscript accessors, so it's not clear how these methods would be 
named.

### Add a `nothrows` keyword

Leaving an accessor's throwing behavior unspecified could make it 
automatically take on the behavior required by the type's superclass or 
conformed protocols. However, this would require a way to explicitly 
state that an accessor could *not* throw, along the lines of the 
rarely-used but necessary `nonmutating` keyword.

I have chosen not to do this because Swift generally does not allow you 
to infer parts of a member's signature, and because I cannot come up 
with a way to spell this keyword that isn't ugly as sin.

### Put commas in protocol accessor declarations

The list of accessors for properties and subscripts, used in protocol 
declarations and generated interfaces (and probably abstract classes if 
they're added later), can be a little confusing to read:

```swift
var property: Int { get throws set throws }
subscript(index: Int) -> Bool { get throws set throws }
```

They get even worse with `mutating` keywords, and would probably become 
unmanageable if other keywords were added:

```swift
var property: Int { mutating get throws nonmutating set throws }
```

Someone suggested privately that we put a comma between each accessor 
to help delimit them:

```swift
var property: Int { mutating get throws, nonmutating set throws }
```

While I agree that this is an issue, and I like this solution, this 
change should be applied to all accessor lists, not just ones with 
throwing accessors. Therefore I believe it should be proposed 
separately.

## Future directions

### Shorthand syntax

It might be helpful to offer a way to declare that both accessors 
throw:

```swift
var property throws: Int { get { ... } set { ... } }
subscript(index: Int) throws -> Bool { get { ... } set { ... } }
```

This is especially compelling for `subscript`, where both accessors may 
use the parameters in similar error-throwing ways.

One challenge is that there's no good place to put `throws` in a 
property declaration. Putting it before the colon looks strange, but 
putting it anywhere else is inconsistent with other uses of `throws`. 
On the other hand, property getters and setters are less likely to 
share invariants, so it may be less valuable there.

This was omitted from the current proposal as both a wholly severable 
enhancement and pure, tooth-decay-inducing syntactic sugar.

### `willSet throws`

Under this proposal, only computed accessors can throw. If you want to 
make a stored property with a throwing accessor, you must wrap it in a 
computed property:


```swift
var _url: NSURL
var url: NSURL {
    get { return _url }
    set throws {
        try newValue.checkResourceIsReachable()
        _url = newValue
    }
}
```

This boilerplate could be avoided by allowing you to specify a throwing 
`willSet` observer. The presence of a `willSet throws` observer would 
imply that the setter itself is `throws`.

```swift
var url: NSURL {
    willSet throws {
      try newValue.checkResourceIsReachable()
    }
}
```

Additionally, `didSet` could support this feature, though that would be 
mistake-prone since the assignment would have already been performed.

I believe `willSet throws` is a clean and useful extension to throwing 
accessors and should be included in Swift. However, it is fully 
severable from the main proposal, so I have subsetted it out to reduce 
the complexity of this proposal.

### Generic rethrowing

One downside of Swift's use of [typed error propagation](https://github.com/apple/swift/blob/master/docs/ErrorHandlingRationale.rst#id46) 
is that, if (for instance) a protocol requirement doesn't normally need 
to throw but some particular conforming type is implemented in such a 
way that all of its members can throw errors, there is no way for that 
type to conform.

For example, consider a database library's `PreparedQuery` type. This 
type is, in most respects, a shoe-in for `Sequence` conformance, which 
would allow you to loop over the records matching the query. However, 
unlike other `Sequence`s, any of `PreparedQuery`'s operations might 
throw an error: the process may lose its connection to the database 
server. It doesn't make sense to change `Sequence` so that its 
requirements are marked as `throws`—the vast majority of `Sequence`s 
never throw, so it would be burdensome to always permit throwing just 
for the very few types which need it—but it's also unfortunate that 
types which need to throw are locked out.

This problem could be solved with a mechanism that allowed a particular 
conforming type to say that *all* of the requirements of the protocol 
can throw.

To give you an idea of what I'm talking about, here's a brief sketch of 
a possible design:

* Protocols can opt in to participating in this "all members might 
  actually throw for some types" semantic:
  
  ```swift
  // The `rethrows` keyword indicates that some conforming types may 
  // make all members throw.
  protocol IteratorProtocol rethrows {
      associatedtype Element
      // There is no explicit indication on the individual members.
      mutating func next() -> Element?
  }
  protocol Sequence rethrows {
      // Without a `rethrows` here, all SequenceType.Generators would 
      // have to be non-throwing.
      associatedtype Iterator: IteratorProtocol rethrows
      // Other members omitted; you get the idea.
  }
  ```

* A conforming type which wants to throw marks its conformance:
  
  ```swift
  class PreparedQuery: Sequence throws {
      // In a concrete type with a throwing conformance, the members 
      // are explicitly marked as `throws`.
      func makeIterator() throws -> ResultIterator {
          return try ResultIterator(query: self)
      }
  }
  ```

* Code which uses a known-throwing concrete type, or which uses 
  protocol types opted in with a `rethrows` keyword, must mark possibly 
  throwing operations with some form of `try`.
  
  ```swift
  let query = database.makeQuery("SELECT name FROM users")
  let names = try query.map { record in try record["name"]! }
  
  func names<Records: Sequence rethrows where Records.Iterator.Element == Record>
      (from records: Records) throws -> [String] {
      return records.map { record in try record["name"]! }
  }
  ```

* The `rethrows` keyword on a function now takes into account not only 
  throwing closure parameters, but also types which have, or may have, 
  throwing conformances.
  
  ```swift
  func countElements<Seq: Sequence rethrows>(_ seq: Seq) rethrows -> Int {
      return try seq.reduce(0) { $0 + 1 }
  }
  ```

There are several possible designs in this space, so any proposal along 
these lines might differ in its details, but I hope you understand what 
I'm getting at here.

The important point in sketching this idea is that it is only possible 
if *all* members of a protocol can throw. If (as suggested in the 
"Alternatives considered" section) getters could not throw, this 
feature would not be able to work.
    