# Smart KeyPaths: Better Key-Value Coding for Swift

* Proposal: [SE-0161](0161-key-paths.md)
* Authors: [David Smith](https://github.com/Catfish-Man), [Michael LeHew](https://github.com/mlehew), [Joe Groff](https://github.com/jckarter)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active review (March 30...April 5, 2017)**
* Associated PRs:
   * [#644](https://github.com/apple/swift-evolution/pull/644)

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
We propose expanding the capabilities of the `#keyPath` directive to produce `KeyPath` objects instead of `Strings`. `KeyPaths` are a family of generic classes _(structs and protocols here would be ideal, but requires generalized existentials)_ which encapsulate a property reference or chain of property references, including the type, mutability, property name(s), and ability to set/get values.

Here's a sample of it in use:

```swift
class Person {
    var name: String
    var friends: [Person] = []
    var bestFriend: Person? = nil
    init(name: String) {
        self.name = name
    }
}

var han = Person(name: "Han Solo")
var luke = Person(name: "Luke Skywalker")
luke.friends.append(han)

// create a key path and use it
let firstFriendsNameKeyPath = #keyPath(Person, .friends[0].name)
let firstFriend = luke[keyPath: firstFriendsNameKeyPath] // "Han Solo"

// or equivalently, with type inferred from context
luke[keyPath: #keyPath(.friends[0].name)] // "Han Solo"

// rename Luke's first friend
luke[keyPath: firstFriendsNameKeyPath] = "A Disreputable Smuggler"

// optional properties work too
let bestFriendsNameKeyPath = #keyPath(Person, .bestFriend?.name) 
let bestFriendsName = luke[keyPath: bestFriendsNameKeyPath]  // nil, if he is the last Jedi
```

## Detailed design
### Core KeyPath Types
`KeyPaths` are a hierarchy of progressively more specific classes, based on whether we have prior knowledge of the path through the object graph we wish to traverse. 

##### Unknown Path / Unknown Root Type
`AnyKeyPath` is fully type-erased, referring to 'any route' through an object/value graph for 'any root'.  Because of type-erasure many operations can fail at runtime and are thus optional. 

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
If we know a little more type information (what kind of thing the key path is relative to), then we can use `PartialKeyPath<Root>`, which refers to an 'any route' from a known root:

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
When we know both what the path is relative to and what it refers to, we can use `KeyPath<Root, Value>`.  Thanks to the knowledge of the `Root` and `Value` types, all of the failable operations lose their `Optional`.  

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
    subscript(keyPath path: AnyKeyPath) -> Any? { get }
    subscript<Root: Self>(keyPath path: PartialKeyPath<Root>) -> Any { get }
    subscript<Root: Self, Value>(keyPath path: KeyPath<Root, Value>) -> Value { get }
    subscript<Root: Self, Value>(keyPath path: WritableKeyPath<Root, Value>) -> Value { set, get }
}
```

This allows for code like

```swift
let someKeyPath = ... 
person[keyPath: someKeyPath]
```

which is both appealingly readable, and doesn't require read-modify-write copies (subscripts access `self` inout). Conflicts with existing subscripts are avoided by using a named parameter and generics to only accept key paths with a `Root` of the type in question.

### Referencing Key Paths
Forming a `KeyPath` borrows from the same syntax added in Swift 3 to confirm the existence of a given key path, only now producing concrete values instead of Strings.  Optionals are handled via optional-chaining. Multiply dotted expressions are allowed as well, and work just as if they were composed via the `appending` methods on `KeyPath`.


There is no change or interaction with the #keyPath() syntax introduced in Swift 3. `#keyPath(Person.bestFriend.name)` will still produce a String, whereas `#keyPath(Person, .bestFriend.name)` will produce a `KeyPath<Person, String>`.

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
We also explored many different spellings, each with different strengths. We have chosen the current syntax for the clarity and discoverability it provides in practice.

| `#keyPath` | Function Type Reference | Lisp-style |
| --- | --- | --- |
| `#keyPath(Person, .friends[0].name)` | `Person.friends[0].name` | \``Person.friend.name` |
| `#keyPath(luke, .friends[0].name)` |`luke[.friends[0].name]`  | `luke`\``.friends[0].name` |
| `#keyPath(luke.friends[0], .name)`| `luke.friends[0][.name]` |  `luke.friends[0]`\``.name` |

While the crispness of the function-type-reference is appealing, it becomes ambigious when working with type properties.  The spelling of the escape-sigil of the Lisp-style remains a barrier to adoption, but could be considered in the future should `#keyPath` prove a burden.

We think most of the situations where `#keyPath` could be overly taxing likely wont show up outside of demonstrative examples:

```swift
// you would likely never type this:
#keyPath(Person, .friends).appending(#keyPath(Array, [0]))

// since you can just type this:
#keyPath(Person, .friends[0])

// .appending is more likely used in situations like this:
let somePath : PartialKeyPath<[Person]> =  ... 
#keyPath(Person, .friends).appending(somePath)

// similarly, you'd never type this:
person[keyPath: #keyPath(Person, .friends[0]))

// since that is just a roundabout way of saying:
person.friends[0]
```

