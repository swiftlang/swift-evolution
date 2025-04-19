# SE-NNNN: Pack Destructuring & Pack Splitting

* Proposal: SE-0XXX  
* Authors: Oguz Yuksel
* Review Manager: TBD  
* Status: Draft  

## Introduction  
Swift’s variadic generics story (SE‑0393 “Parameter Packs” and SE‑0408 “Pack Iteration”) unlocks powerful abstractions over arbitrary arities. However, two missing features—recursive decomposition of packs in patterns and split‑expansion of packs at call sites—force library authors into brittle workarounds like fixed‑arity overloads or type erasure. This proposal completes the variadic‑generic toolbox by introducing:

1. **Pack Destructuring in Patterns** – extract `head` and `tail` from a variadic tuple in a `let` or `switch` pattern.  
2. **Pack Splitting in Calls** – feed a single parameter‐pack expansion into separate head + tail parameters at call sites.

These additions eliminate boilerplate, remove arbitrary arity limits, and enable truly recursive generic algorithms.

## Motivation  
- **No recursive pack decomposition**: We cannot peel off the first element of a parameter pack at compile time.  
- **Fixed‑arity overloads & limits**: Combine’s `zip` (up to 10 overloads) and SwiftUI’s `TupleView` (10 views max) are symptomatic workarounds.  
- **Type erasure** sacrifices compile‑time safety and incurs runtime costs (`[AnyPublisher]`).  
- **Goal**: Give library authors a first‐class, type‑safe, zero‑overhead mechanism to recurse over arbitrary variadic tuples.

## Proposed Solution  
I propose two orthogonal features:

1. **Pack Destructuring in Patterns**  
2. **Pack Splitting in Calls**

Both are purely compile‑time, require no ABI changes, and integrate smoothly with existing tuple layout and call‐site resolution rules.

## Detailed Design

### Pack Destructuring in Patterns  
**Syntax**  
```swift
let (head, repeat each tail) = variadicTuple
```

**Semantics**  
- `head` binds to the first element of the tuple.  
- `tail` binds to a new pack containing the remaining elements.  
- Exactly one `repeat each` may appear per tuple‐level.  

**Examples**  
```swift
// New: peel off first element
let tuple: (Int, String, Bool) = (1, "a", true)
let (first, repeat each rest) = tuple
// first:  Int = 1
// rest:   (String, Bool)

switch result {
case .success(let firstValue, repeat each otherValues):
    process(firstValue, repeat each otherValues)
case .failure(let error):
    handleError(error)
}
```

**Static Checks**  
- If the pack is empty, pattern matching fails (compile‐time error).  
- Only one `repeat each` per tuple—extra expansions or mismatched arity are diagnostics.

### Pack Splitting in Calls  
**Syntax**  
```swift
func process(_ head: Head, _ tail: repeat each Tail) { … }

// Given a pack:
let pack: (A, B, C, D) = (…)

// Call with split:
process(repeat each pack)
// Desugars to:
//   process(pack.0, (pack.1, pack.2, pack.3))
```

**Semantics**  
1. Non‑pack parameters bind first (in declaration order).  
2. A single `repeat each` parameter consumes all remaining elements as a pack.  

**Example**  
```swift
func flatten(_ values: repeat each T) -> (repeat each T) {
    guard let (first, repeat each rest) = (repeat each values) else {
        return ()  // empty pack
    }
    return (first, repeat each flatten(rest))
}
```

## Technical Design

### Grammar Extension  
```ebnf
tuple-pattern-element → pattern
                      | 'repeat' 'each' identifier
tuple-expression-element → expression
                         | 'repeat' 'each' pack-expression
```

### AST & Type System  
- Introduce `PackExpansionPattern` and `PackExpansionExpr` nodes.  
- Enforce at most one `repeat each` at each tuple nesting level.  
- Match arity at compile time; no runtime checks needed.

### Source Compatibility  
This feature is purely additive. Existing code—packs, expansions, and overload resolution—continues to compile without change.

### ABI Stability  
No new runtime structures or calling conventions are introduced. All destructuring is compiled to existing tuple projection instructions.

### Performance  
Compile‑time type checking adds negligible cost. Generated code for tuple access and calls is identical to hand‑written projections.

## Argument Binding Rules  
1. Bind all non‑pack parameters in declaration order.  
2. The single `repeat each` parameter then consumes the remaining arguments as one pack.  
3. Extra or missing arguments produce diagnostics as usual.

```swift
func accept(a: Int, b: String, c: repeat each C) { … }

// Valid:
accept(repeat each (1, "a", true, false))
// a = 1, b = "a", c = (true, false)

// Error: too few args
accept(repeat each (1, "a"))
```

## Impact on Standard Library & Real‑World Examples

### Combine.zip Before  
```swift
// 10+ overloads:
func zip<A,B>(_ a: A, _ b: B) -> Zip2<A,B>
func zip<A,B,C>(_ a: A, _ b: B, _ c: C) -> Zip3<A,B,C>
// … up to Zip10
```

### Combine.zip After  
```swift
struct Zip<repeat each S>: Publisher {
  typealias Output = (repeat (each S).Output)

  let publishers: (repeat each S)

  func receive<Sub: Subscriber>(subscriber: Sub) where Sub.Input == Output {
    let (first, repeat each rest) = publishers
    first.receive(ZipHelper(subscriber, rest))
  }
}
```

**Result**: ~250 LOC → ~20 LOC, no fixed arity limit, compile‑time safety preserved.

## Future Directions  
- **Multi‑Pack Operations**  
  ```swift
  func zip(_ s1: repeat each S1, _ s2: repeat each S2) -> (repeat each (S1, S2))
  ```
- **Named Pack Elements**  
  ```swift
  let (header: repeat each headers, body: repeat each bodies) = httpResponse
  ```
- **Variadic async/await**  
  ```swift
  async let (firstResult, repeat each partials) = fetchAll(repeat each requests)
  ```

## Alternatives Considered  

### 1. Fixed‑Arity Overloads  
- Pros: trivial, no language changes  
- Cons: boilerplate, arbitrary limits, code bloat  


## References  
1. [SE‑0393: Parameter Packs](https://github.com/apple/swift-evolution/blob/main/proposals/0393-parameter-packs.md) – Introduces variadic type‐parameter packs.  
2. [SE‑0408: Pack Iteration](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0408-pack-iteration.md) – Enables iteration over packs.  

## Conclusion  
By adding pack destructuring in patterns and pack splitting in calls, this proposal fills the last gaps in Swift’s variadic‑generic capabilities. Library authors can now write truly recursive, zero‑overhead abstractions without fixed arity limits or type erasure, while preserving source and ABI compatibility.
