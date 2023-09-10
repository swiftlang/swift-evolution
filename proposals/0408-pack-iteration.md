# Pack Iteration

* Proposal: [SE-0408](0408-pack-iteration.md)
* Authors: [Sima Nerush](https://github.com/simanerush), [Holly Borla](https://github.com/hborla)
* Review Manager: [Doug Gregor](https://github.com/DougGregor/)
* Status: **Active Review (September 6...19, 2023)**
* Implementation: [apple/swift#67594](https://github.com/apple/swift/pull/67594) (gated behind flag `-enable-experimental-feature PackIteration`)
* Review: ([pitch](https://forums.swift.org/t/pitch-enable-pack-iteration/66168), [review](https://forums.swift.org/t/review-se-0408-pack-iteration/67152))

## Introduction

Building upon the Value and Type Parameter Packs proposal [SE-0393](https://forums.swift.org/t/se-0393-value-and-type-parameter-packs/63859), this proposal enables iterating over each element in a value pack and bind each value to a local variable using a `for-in` syntax.


## Motivation

Currently, it is possible to express list operations on value packs using pack expansion expressions. This approach requires putting code involving statements into a function or closure. For example, limiting repetition patterns to expressions does not allow for short-circuiting with `break` or `continue` statements, so the pattern expression will always be evaluated once for every element in the pack. The only way to stop evaluation would be to mark the function/closure containing the pattern expression throwing, and catch the error in a do/catch block to return, which is unnatural for Swift users.

The following implementation of `==` over tuples of arbitrary length demonstrates these workarounds:

```swift
struct NotEqual: Error {}

func == <each Element: Equatable>(lhs: (repeat each Element), rhs: (repeat each Element)) -> Bool {
  // Local throwing function for operating over each element of a pack expansion.
  func isEqual<T: Equatable>(_ left: T, _ right: T) throws {
    if left == right {
      return
    }
    
    throw NotEqual()
  }

  // Do-catch statement for short-circuiting as soon as two tuple elements are not equal.
  do {
    repeat isEqual(each lhs, each rhs)
  } catch {
    return false
  }

  return true
}
```

Here, the programmer can only return `false` when the `NotEqual` error was thrown. The `isEqual` function performs the comparison and throws if the sides are not equal. 

## Proposed Solution

We propose allowing iteration over value packs using `for-in` loops. With the adoption of pack iteration, the implementation of the standard library methods like `==` operator for tuples of any number of elements will become straightforward. Instead of throwing a `NotEqual` error, the function can simply iterate over each respective element of the tuple and `return false` in the body of the loop if the elements are not equal:

```swift
func == <each Element: Equatable>(lhs: (repeat each Element), rhs: (repeat each Element)) -> Bool {

  for (left, right) in repeat (each lhs, each rhs) {
    guard left == right else { return false }
  }
  return true
}
```

The above code iterates pairwise over two tuples `lhs` and `rhs` using a `for-in` loop syntax. At each iteration, the pack elements of `lhs` and `rhs` are bound to the local variables `left` and `right`, respectively. Because `lhs` and `rhs` have the same type, so do `left` and `right`, and the `Equatable` requirement allows comparing `left` and `right` with `==`.

## Detailed Design

In addition to expressions that conform to `Sequence`, the source of a `for-in` loop can be a pack expansion expression. 

```swift
func iterate<each Element>(over element: repeat each Element) {
  for element in repeat each element {
  
  }
}
```

On the *i*th iteration, the type of `element` is the *i*th type parameter in the `Element` type parameter pack, and the value of `element` is the *i*th value parameter in the shadowed `element` value parameter pack. Conceptually, the type of `element` is the pattern type of `repeat each element` with each captured type parameter pack replaced with an implicit scalar type parameter with matching requirements. In this case, the pattern type is `each Element`, so the type of `element` is a scalar type parameter with no requirements. Let’s call the scalar type parameter `Element'`. For example, if `iterate` is called with `each Element` bound to the type pack `{Int, String, Bool}` the body of the `for-in` loop will first substitute `Element'` for `Int`, then `String`, then `Bool`.

If the type parameter packs captured by the pack expansion pattern contain requirements, the scalar type parameter in the loop body will have the same requirements:

```swift
struct Generic<T> {}

protocol P {}

func iterate<each Element: P>() {
  for x in repeat Generic<each Element>() {
    // the type of 'x' is <Element': P> Generic<Element'>
  }
}
```

In the above code, the pattern type of the pack expansion is `Generic<each Element>` where `each Element: P`, so the type of `x` is a scalar type parameter `<Element'> where Element': P`.

Like regular `for-in` loops, `for-in` loops over pack expansions can pattern match over each element of the value pack:

```swift
enum E<T> {
  case one(T)
  case two
}

func iterate<each Element>(over element: repeat E<each Element>) {
  for case .one(let value) in repeat each element {
    // 'value' has type <Element'> Element'
  }
}
```
The pattern expression in the source of a `for-in repeat` loop is evaluated once at each iteration, instead of `n` times eagerly where `n` is the length of the packs captured by the pattern. If `p_i` is the pattern expression at the `i`th iteration and control flow exits the loop at iteration `i`, then `p_j` is not evaluated for `i < j < n`. For example:

```swift
func printAndReturn<Value>(_ value: Value) -> Value {
  print("Evaluated pack element value \(value)")
  return value
}

func iterate<each T>(_ t: repeat each T) {
  var i = 0
  for value in repeat printAndReturn(each t) {
    print("Evaluating loop iteration \(i)")
    if i == 1 { 
      break 
    } else {
      i += 1
    }
  }
  
  print("Done iterating")
}

iterate(1, "hello", true)
```

The above code has the following output

```
Evaluated pack element value 1
Evaluating loop iteration 0
Evaluated pack element value "hello"
Evaluating loop iteration 1
Done iterating
```

## Source Compatibility

There is no source compatibility impact, since this is an additive change.


## ABI Compatibility

This proposal does not affect ABI, since its impact is only in expressions.


## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no deployment constraints and without affecting source or ABI compatibility.

## Alternatives Considered

The only alternative to allowing pack iteration would be placing code with statements into functions/closures, however, that approach is unnatural and over-complicated. For example, this is a version of the `==` operator for tuples implementation mentioned earlier.

## Future directions

### Enabling `guard let`

Another familiar pattern to Swift programmers is `guard let`. 

For example, consider the `zip` function from the standard library. `guard let` can be used for enabling this function to support any number of sequences, instead of just 2:

```swift
public func zip<each S: Sequence>(_ sequences: repeat each S) -> ZipSequence<repeat each S> {
  .init(sequences: repeat each sequences)
}

public struct ZipSequence<each S: Sequence> {
  let sequences: (repeat each S)
}

extension ZipSequence: Sequence {
    public typealias Element = (repeat (each S).Element)
    
    public struct Iterator: IteratorProtocol {
        var iterators: (repeat (each S).Iterator)
        var reachedEnd = false
        
        public mutating func next() -> Element? {
            if reachedEnd {
                return nil
            }
            
            // Using guard let for checking that the next element is not nil.
            guard let element = repeat (each iterators).next() else {
                return nil
            }

            return (repeat each element)
        }
    }
    
    public func makeIterator() -> Iterator {
        return Iterator(iter: (repeat (each sequences).makeIterator()))
    }
}
```

