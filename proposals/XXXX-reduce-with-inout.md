# Feature name

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Chris Eidhof](https://github.com/chriseidhof)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

A new variant of `reduce` should be added to the standard library. Instead of taking a `combine` function that is of type `(A, Iterator.Element) -> A`, the full type and implementation of the added `reduce` will be:

```swift
extension Sequence {
    func reduce<A>(_ initial: A, combine: (inout A, Iterator.Element) -> ()) -> A {
        var result = initial
        for element in self {
            combine(&result, element)
        }
        return result
    }
}
```

Swift-evolution thread: [Reduce with inout](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170116/030300.html)

## Motivation

The current version of `reduce` needs to make copies of the result type for each element in the sequence. The proposed version can eliminate the need to make copies (when the `inout` is optimized away).

## Proposed solution

The first benefit of the proposed solution is efficiency. The new version of `reduce` can be used to write efficient implementations of methods that work on `Sequence`. For example, consider an implementation of `uniq`, which filters adjacent equal entries:

```swift
extension Sequence where Iterator.Element: Equatable {
    func uniq() -> [Iterator.Element] {
        return reduce([]) { (result: inout [Iterator.Element], element) in
            if result.last != element {
                result.append(element)
            }
        }
    }
}
```

In the code above, the optimizer will usually optimize the `inout` array into an `UnsafeMutablePointer`, or when inlined, into a simple mutable variable. With that optimization, the complexity of the algorithm is `O(n)`. The same algorithm, but implemented using the existing variant of reduce, will be `O(n²)`, because instead of `append`, it copies the existing array in the expression `result + [element]`:

```swift
extension Sequence where Iterator.Element: Equatable {
    func uniq() -> [Iterator.Element] {
        return reduce([]) { (result: [Iterator.Element], element) in
            guard result.last != element else { return result }
            return result + [element]
        }
    }
}
```

The second benefit is that the new version of `reduce` is more natural when dealing with `mutating` methods. For example, consider a function that computes frequencies in a `Sequence`:

```swift
extension Sequence where Iterator.Element: Hashable {
    func frequencies() -> [Iterator.Element: Int] {
        return reduce([:]) { (result: inout [Iterator.Element:Int], element) in
            if let value = result[element] {
                result[element] = value + 1
            } else {
                result[element] = 1
            }
        }
    }
}
```

Without the `inout` parameter, we'd first have to make a `var` copy of the existing result, and have to remember to return that copy instead of the `result`. (The method above is probably clearer when written with a `for`-loop, but that's not the point).


## Source compatibility

This is purely additive, we don't propose removing the existing `reduce`.

## Effect on ABI stability

N/A

## Effect on API resilience

N/A

## Alternatives considered

We considered removing the existing `reduce`, but the problem with that is two-fold. First, it breaks existing code. Second, it's useful for algorithms that don't use mutating methods within `combine`. 

Under active discussion: the naming of this method. See the [swift-evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170116/030300).
