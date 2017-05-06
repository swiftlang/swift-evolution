# Pattern Matching Partial Function

* Proposal: [SE-0024](https://github.com/apple/swift-evolution/blob/master/proposals/0024-Pattern-Matching-Partial-Function.md)
* Author(s): [Craig Cruden](https://github.com/cacruden)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Provide the ability for defining partial functions using familiar `case`/`default` pattern matching syntax. A new global `match` function would use this to provide switch-expression functionality for all types. This function would accept a value and a closure containing the `case`/`default` partial functions. Combining `case`/`default` partial functions in a closure must always be exhaustive providing a total function. Functions on arrays, dictionaries or other collections such as `reduce` or `filter`, or rather all higher order functions taking a unary function as argument, would accept these closures as they are just normal closures.

Swift-evolution thread: [ternary operator ?: suggestion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006194.html)

## Motivation

There is currently no elegant methodology within Swift closures to conditionally map values.  This type of scenario occurs often in Swift code and this proposal provides a generalized and flexible solution.  Anywhere a closure is used the developer will also be able to conditionally execute multiple partial closures depending on the mapping of values.  The syntax proposed makes Swift code easier to read, easier to write, and less issue prone.  

The following example where a string is mapped to an enum case is indicative of the problem:

```swift
let str:String
	
switch state {
case .Cold: 
	str = “Too cold”
case .Hot: 
	str = “Too hot”
default: 
	str = “Just right”
}
```
  
The syntax above does not elegantly express our intent as the `switch` statement is designed for “flow control”.  Aside from being limited to choosing a single value our example requires no “flow control”.  In addition, the ability to execute unrelated statements inside the switch statement makes it harder prove correctness of the algorithm.

Alternatives to using `switch` do exist but are unsatisfactory.  A `Dictionary`, for example, increases cognitive load (i.e. requires `Hashable` keys and returns an optional).  This makes it less clear as to what function is being performed.  `Dictionary` also lacks exhautiveness or uniqueness checks which may result in unexpected runtime exceptions.

This proposal provides a simple mechanism which covers many different types of scenarios.  It may be used where the ideal solution is a `switch` expression.  It may also be used to provide a way of simply mapping conditionally between multiple values in two related but different domains.  In addition, it can be used in combination with other functions such as `reduce` and `filter` where the logic is partially conditional.

The syntax is based on familiar `case`/`default` clauses common to switch statements which may be used in functions such as `map`, `filter`, `reduce`.  This makes it easy for the developer to remember and understand.


## Proposed solution

Any function which accepts a closure would also be able to accept a closure composed of partial functions defined using `case`/`default` syntax used in switch-case.  Each `case` or `default`is considered a partial function since it defines the closure for a subset of values.  

```swift
public enum Trade {
    case Buy(quantity: Double, price: Double)
    case Sell(quantity: Double, price: Double)
}

let commissions = trades.map {
    case .Buy(let quantity, let price) where quantity * price > 10000:
        let vipCommissionRate = calculateCommissionRate(...)
        quantity * price * vipCommissionRate / 100
    case .Buy(let quantity, let price):
        let commissionRate = calculateCommissionRate(...)
        quantity * price * commissionRate / 100
    case .Sell(let quantity, let price) where quantity * price > 10000:
        let vipCommissionRate = calculateCommissionRate(...)
        quantity * price * vipCommissionRate / 100
    case .Sell(let quantity, let price):
        let commissionRate = calculateCommissionRate(...)
        quantity * price * commissionRate / 100
}      
```

Each of the case clauses represent a partial closure / partial function.  As with a total closure the case result may be specified with the optional `return` clause.  For example:

```swift
case .Buy(let quantity, let price) where quantity * price > 10000:
    let vipCommissionRate = calculateCommissionRate(...)
    return quantity * price * vipCommissionRate / 100
```

Alternative grammar `cases`/`default` which is a specialized version that can be used for the simplest and the most consise use case.  If the use case is a simple definition of mapping of values then `cases` can be used to define multiple  case clauses. `cases` clause may not be used with a `where` clause.  The purpose of allowing `cases` as syntatic sugar for multiple `case` clauses is to allow a less verbose option for use cases where the developer would use a multi-case ternary expression.
  

```swift
let col = [1,5,7,9]

let newCol = col.map {
	cases 1: "one", 2: "two",   3: "three", 4: "four", 5: "five",
	      6: "six", 7: "seven", 8: "eight", 9: "nine", 0: "zero"
	default: ""
}
```

The following global `match` function would provide switch-expression functionality to all types:  

```swift
func match<T,U>(x: T, @noescape mapping: T -> U) -> U {
    return mapping(x)
}
```

The `match` function would be used similar to the following:

```swift
let n = 5

let s = match(n) {
	cases 1: "one", 2: "two",   3: "three", 4: "four", 5: "five",
	      6: "six", 7: "seven", 8: "eight", 9: "nine", 0: "zero"
	default: ""
}
```

Functions such as `reduce` that receive two or more values must be enclosed in brackets `(x, y)` to otherwise the parser would likely have trouble distinquishing between comma delimited lists of values which are currently allowed as a single case.

```swift
public enum Troy {
    case Pound(Int)
    case Ounce(Int)
    case Pennyweight(Int)
    case Grain(Int)
}

let weightTroy = [Troy.Pound(5), Troy.Ounce(4), Troy.Pennyweight(6), Troy.Grain(9)]

let weightKg = weightTroy.reduce(0.00) {
    case (let acc, Troy.Pound(let quantity)):
        acc + Double(quantity) * 0.373
    case (let acc, Troy.Ounce(let quantity)):
        acc + Double(quantity) * 0.031103
    case (let acc, Troy.Pennyweight(let quantity)):
        acc + Double(quantity) * 0.001555
    case (let acc, Troy.Grain(let quantity)):
        acc + Double(quantity) * 0.0000648
}
```

## Detailed design

Any function which accepts a closure would also be able to accept a closure composed of partial functions defined using `case`/`default` syntax used in switch-case.  Each `case` or `default`is considered a partial function since it defines the closure for a subset of values.  

**GRAMMAR OF A CLOSURE COMPOSED OF PARTIAL FUNCTIONS**

closure → ­ {­switch-cases­<sub>opt</sub>­}­  
switch-cases → switch-case­ switch-cases­<sub>opt</sub>  
switch-case → case-label­ statements­ | default-label­ statements  
case-label → **case­** case-item-list­ :­  
case-item-list → pattern­ where-clause­<sub>opt</sub>­ | pattern ­where-clause­<sub>opt</sub>­ , ­case-item-list­  
default-label → **default**­ :­  
where-clause → **where**­ where-expression­  
where-expression → expression­




Alternative grammar `cases`/`default` which is a specialized version that can be used for the simplest and the most consise use case.  If the use case is a simple definition of mapping of values then `cases` can be used to define multiple  case clauses. `cases` clause may not be used with a `where` clause.  The purpose of allowing `cases` as syntatic sugar for multiple `case` clauses is to allow a less verbose option for use cases where the developer would use a multi-case ternary expression.


**NEW GRAMMAR FOR CONSISE FORM OF CASES**

closure → ­ {­switch-cases­<sub>opt</sub>­}­  
switch-cases → cases-label­ statements­ | default-label­ statements  
cases-label → **cases**­ case-item-map­  
case-item-map → pattern­ : value | pattern : value ­ , ­case-item-list­  
default-label → **default**­:­  



## Impact on existing code

This mechanism is opt-in, so existing code won't be affected by this change.

## Alternatives considered

There were various specialized multi-ternary suggestions made as a replacement/expansion of ternary which supported more than two possible examples, but are more of a specialized case that this proposal should eliminate the need for.  

The only other alternative considered that was a generalized version similar to the proposal above was basically the same but using `in` instead of `:` because we were defining partial functions and not a `switch` command.  The overwelming sentiment was in favour of using exactly the same syntax as the `switch` command where possible.

```swift
public enum Troy {
    case Pound(Int)
    case Ounce(Int)
    case Pennyweight(Int)
    case Grain(Int)
}

let weightTroy = [Troy.Pound(5), Troy.Ounce(4), Troy.Pennyweight(6), Troy.Grain(9)]

let weightKg = weightTroy.reduce(0.00) {
    case (let acc, Troy.Pound(let quantity)) in
        acc + Double(quantity) * 0.373
    case (let acc, Troy.Ounce(let quantity)) in
        acc + Double(quantity) * 0.031103
    case (let acc, Troy.Pennyweight(let quantity)) in
        acc + Double(quantity) * 0.001555
    case (let acc, Troy.Grain(let quantity)) in
        acc + Double(quantity) * 0.0000648
    }
}
```

## Out of Scope

Named partial functions are out of scope for this proposal. 
