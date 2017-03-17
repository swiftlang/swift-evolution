# Smart KeyPaths: Better Key-Value Coding for Swift

* Proposal: SE-NNNN
* Authors: [David Smith](https://github.com/Catfish-Man), [Michael LeHew](https://github.com/mlehew), [Joe Groff](https://github.com/jckarter)
* Review Manager: TBD
* Status: **Awaiting Review**
* Associated PRs:
   * TBD

## Introduction
We propose a family of concrete _Key Path_ types that represent uninvoked references to properties that can be composed to form paths through many values and directly get/set their underlying values.

## Motivation
#### We Can Do Better than String
On Darwin platforms Swift's existing `#keyPath()` syntax provides a convenient way to safely *refer* to properties. Unfortunately, once validated, the expression becomes a `String` which has a number of important limitations:

* Loss of type information (requiring awkward `Any` APIs)
* Unnecessarily slow to parse
* Only applicable to `NSObjects` 
* Limited to Darwin platforms

#### Use/Mention Distinctions
While methods can be referred to without invoking them (`let x = foo.bar` instead of  `let x = foo.bar()`), this is not currently possible for properties and subscripts.

Making indirect references to a properties' concrete types also lets us expose metadata about the property, and in the future additional behaviors.

#### More Expressive KeyPaths
We would also like to support being able to use _Key Paths_ to access into collections, which is not currently possible.

## Proposed solution
We propose introducing a new expression akin to `Type.method`, but for properties and subscripts. These property reference expressions produce `KeyPath` objects, rather than `Strings`. `KeyPaths` are a family of generic classes _(structs and protocols here would be ideal, but requires generalized existentials)_ which encapsulate a property reference or chain of property references, including the type, mutability, property name(s), and ability to set/get values.

Here's a sample of it in use:

```swift
struct Person {
	var name: String
	var friends: [Person]
	var bestFriend: Person?
}

var han = Person(name: "Han Solo", friends: [])
var luke = Person(name: "Luke Skywalker", friends: [han])

let firstFriendsNameKeyPath = Person.friends[0].name

let firstFriend = luke[path] // han

// or equivalently, with type inferred from context
let firstFriendName = luke[.friends[0].name]

// rename Luke's first friend
luke[firstFriendsNameKeyPath] = "A Disreputable Smuggler"

let bestFriendsName = luke[.bestFriend]?.name  // nil, if he is the last jedi
```

## Detailed design
### Core KeyPath Types
`KeyPaths` are a hierarchy of progressively more specific classes, based on whether we have prior knowledge of the path through the object graph we wish to traverse. 

##### Unknown Path / Unknown Root Type
`AnyKeyPath` is fully type-erased, referring to 'any route' through an object/value graph for 'any root'.  Because of type-erasure many operations can fail at runtime and are thus nillable. 

```swift
class AnyKeyPath: CustomDebugStringConvertible, Hashable {
    // MARK - Composition
    // Returns nil if path.rootType != self.valueType
    func appending(path: AnyKeyPath) -> AnyKeyPath?
    
    // MARK - Runtime Information        
    class var rootType: Any.Type
    class var valueType: Any.Type
    
    static func == (lhs: AnyKeyPath, rhs: AnyKeyPath) -> Bool
    var hashValue: Int
}
```
##### Unknown Path / Known Root Type
If we know a little more type information (what kind of thing the key path is relative to), then we can use `PartialKeyPath <Root>`, which refers to an 'any route' from a known root:

```swift
class PartialKeyPath<Root>: AnyKeyPath {
    // MARK - Composition
    // Returns nil if Value != self.valueType
    func appending(path: AnyKeyPath) -> PartialKeyPath<Root>?
    func appending<Value, AppendedValue>(path: KeyPath<Value, AppendedValue>) -> KeyPath<Root, AppendedValue>?
    func appending<Value, AppendedValue>(path: ReferenceKeyPath<Value, AppendedValue>) -> ReferenceKeyPath<Root, AppendedValue>?
}
```

##### Known Path / Known Root Type
When we know both what the path is relative to and what it refers to, we can use `KeyPath`.  Thanks to the knowledge of the Root and Value types, all of the failable operations lose their Optional.  

```swift
public class KeyPath<Root, Value>: PartialKeyPath<Root> {
    // MARK - Composition
    func appending<AppendedValue>(path: KeyPath<Value, AppendedValue>) -> KeyPath<Root, AppendedValue>
    func appending<AppendedValue>(path: WritableKeyPath<Value, AppendedValue>) -> Self
    func appending<AppendedValue>(path: ReferenceWritableKeyPath<Value, AppendedValue>) -> ReferenceWritableKeyPath<Root, AppendedValue>
}
```

##### Value/Reference Mutation Semantics Mutation
Finally, we have a pair of subclasses encapsulating value/reference mutation semantics. These have to be distinct because mutating a copy of a value is not very useful, so we need to mutate an inout value.

```swift
class WritableKeyPath<Root, Value>: KeyPath<Root, Value> {
    // MARK - Composition
    func appending<AppendedPathValue>(path: WritableKeyPath<Value, AppendedPathValue>) -> WritableKeyPath<Root, AppendedPathValue>
}

class ReferenceWritableKeyPath<Root, Value>: WritableKeyPath<Root, Value> {
    override func appending<AppendedPathValue>(path: WritableKeyPath<Value, AppendedPathValue>) -> ReferenceWritableKeyPath<Root, AppendedPathValue>
}
```


### Access and Mutation Through KeyPaths
To get or set values for a given root and key path we effectively add the following subscripts to all Swift types. 

```swift
extension Any {
    subscript(path: AnyKeyPath) -> Any? { get }
    subscript<Root: Self>(path: PartialKeyPath<Root>) -> Any { get }
    subscript<Root: Self, Value>(path: KeyPath<Root, Value>) -> Value { get }
    subscript<Root: Self, Value>(path: WritableKeyPath<Root, Value>) -> Value { set, get }
}
```

This allows for code like

```swift
person[.name] // Self.type is inferred
```

which is both appealingly readable, and doesn't require read-modify-write copies (subscripts access `self` inout). Conflicts with existing subscripts are avoided by using generic subscripts to specifically only accept key paths with a `Root` of the type in question.

### Referencing Key Paths
Forming a `KeyPath` borrows from the same syntax used to reference methods and initializers,`Type.instanceMethod` only now working for properties and collections. Optionals are handled via optional-chaining. Multiply dotted expressions are allowed as well, and work just as if they were composed via the `appending` methods on `KeyPath`.

There is no change or interaction with the #keyPath() syntax introduced in Swift 3. 

### Performance
The performance of interacting with a property via `KeyPaths` should be close to the cost of calling the property directly.

## Source compatibility
This change is additive and there should no affect on existing source. 

## Effect on ABI stability
This feature adds the following requirements to ABI stability: 

- mechanism to access key paths of public properties

We think a protocol-based design would be preferable once the language has sufficient support for generalized existentials to make that ergonomic. By keeping the class hierarchy closed and the concrete implementations private to the implementation it should be tractable to provide compatibility with an open protocol-based design in the future.

## Effect on API resilience
This should not significantly impact API resilience, as it merely provides a new mechanism for operating on existing APIs.

## Alternatives considered

#### More Features
Various drafts of this proposal have included additional features (decomposable key paths, prefix comparisons, support for custom `KeyPath` subclasses, creating a `KeyPath` from a `String` at runtime, `KeyPaths` conforming to `Codable`, bound key paths as a concrete type, etc.).  We anticipate approaching these enhancements additively once the core `KeyPath` functionality is in place. 

#### Spelling
We also explored many different spellings, each with different strengths. We have chosen the current syntax due to the balance with existing function type references.

| Current | `#keyPath` | Lisp-style |
| --- | --- | --- |
| `Person.friends[0].name`  | `#keyPath(Person, .friends[0].name)` | \``Person.friend.name` |
| `luke[.friends[0].name]` |  `#keyPath(luke, .friends[0].name)` | `luke`\``.friends[0].name` |
| `luke.friends[0][.name]` | `#keyPath(luke.friends[0], .name)` |  `luke.friends[0]`\``.name` |
 

While the crispness is very appealing, the spelling of the 'escape' character was hard to agree upon (along with the fact that it requires parentheses to reduce ambiguity).  `#keyPath` was very specific, but verbose especially when composing multiple key paths together. 
