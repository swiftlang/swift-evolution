# Implement The Pipeline Operator

* Proposal: [SE-0145](0145-implement-the-pipeline-operator.md)
* Authors: [Matheus Albuquerque](https://github.com/ythecombinator), [Marcelo Camargo][https://github.com/haskellcamargo)
* Review Manager: TBD
* Status: **Awaiting review**

## Sidenote

I think that implementing a **function composition operator** ─ e.g.
`>>` ─ would be in the very same scope of this proposal but, in order to make
this proposal more *atomic*, changes here are concerned only to the
**pipeline operator**.

The composition infix operators take two functions and return another function; 
**by contrast, the pipeline operators take a function and an argument and return a value**.

## Introduction

This proposal introduces a new operator, `|>`, found in many other languages, such as:
- [F#](https://en.wikibooks.org/wiki/F_Sharp_Programming/Higher_Order_Functions#The_.7C.3E_Operator), 
- [OCaml](http://caml.inria.fr/pub/docs/manual-ocaml/libref/Pervasives.html#VAL%28|%3E%29), 
- [Elixir](https://www.safaribooksonline.com/library/view/programming-elixir/9781680500530/f_0057.html),
- [Hack](https://docs.hhvm.com/hack/operators/pipe-operator),

Several other languages support them; as well as UNIX pipes. It's a simple ─ yet 
**backwards-compatible** ─ way of streamlining chained function calls in a 
**readable**, **functional** manner.

## Motivation

Using the `.` operator is the most common - and clean as well - way to chain together instance method calls.

However, it does not help when we want to chain together method calls between distinct entities or stand-alone functions.

Let's say we have the following simple function definitions:

```swift
// Takes a single value of type `Int` and increments it:

func increment(x: Int) -> Int {
    return x + 1
}

// Takes a single value of type `Int` and squares it:

func square(x: Int) -> Int {
    return x * x
}
``` 

To increment and afterwards square a value, we would do something like this:

```swift
let myValue: Int = 66
let myNewValue: Int = square(increment(myValue))
``` 

We have to read the function applications **inside-out**. First, 
`increment(myValue)` is evaluated, and then the result of that expression is 
passed to the `square` function. Yet, from left to right, we write square before
increment, **messing the application order**.

In this case, we have a simple `f(g(x))`, but it is very likely for us to find 
real-world scenarios where we would deal with something like: 
`f(g(h(i(j(x)))))` - and *Jason Larsen* gives us a good example on this 
[here](http://jasonlarsen.me/2015/05/23/pipes.html):

```swift
let students = Database.allStudents()
let grades = Grades.forStudents(students)
let curvedGrades = curve(grades, average: 0.6)
let finalGrades = prepareGrades(curvedGrades)
```

As he states:

> This code is simple and has clear variable naming. However, even with clear
variable names, it may still be difficult for a reader to immediately realize 
that each variable declaration’s real purpose is only to hold a value to be used 
in the next line. These temporary variables introduce noise that may obfuscate 
the simple flow of data. So why all the temporary variables?

The alternative ends up being:

```swift
let finalGrades = prepareGrades(curve(Grades.forStudents(Database.allStudents()), average: 0.6))
```

Which is something that deep: `f(g(h(i(x))))`.

Still in real-world scenarios, it is nothing uncommom to see something like
the example below when feeding an `UIImageView` with an image fetched from a URL:

```swift
let imageURLString: String = "https://avatars2.githubusercontent.com/u/10639145"

if let imageURL = URL(string: imageURLString) {
    if let imageData = NSData(contentsOf: imageURL) {
        if let image = UIImage(data: imageData as Data) {
            let imageView = UIImageView(image: image)
        }
    }
}
``` 

Again, it is not very concise and makes it harder to read and understand the 
code flow at first sight.

As we can find in the great masterpiece [SICP, *Structure and Interpretation of Computer Programs*](https://mitpress.mit.edu/sicp/full-text/sicp/book/node4.html): 

> *Computational processes* are abstract beings that inhabit computers. As they
evolve, processes manipulate other abstract things called *data*. The evolution
of a process is directed by a pattern of rules called a *program*. 
**People create programs to direct processes**.

We know that, in essence, programs transform data. Input data are somehow
manipulated and returned as output data - so **it is very important to have have
our have our data flow clearly defined and concise**.

## Proposed solution

Although Swift is not really a functional programming language, it does 
support a few functional-programming patterns - and has a *well-designed 
type system* -, so many functional programming lovers ended up by 
implementing their favorite functional idioms and libraries from other 
programming languages in Swift. Good examples on this are libraries like
[Swiftz](https://github.com/typelift/Swiftz),
[Dollar](https://github.com/ankurp/Dollar)
and even [some ports of the prelude](https://github.com/robrix/Prelude).

A feature many developers are used to - and actually love - in many funcional
programming languages is their **Pipeline Operator** - also known as 
**Pipe-Forward** operator - `|>` -, which helps to write readable functional 
code by allowing developers to **apply the left hand side of the expression as 
the first argument in the function on the right - enabling function calls to be chained together as successive operations**.

It is currently implemented in:

- [Elixir](https://elixirschool.com/lessons/basics/pipe-operator/)
- [F#](https://en.wikibooks.org/wiki/F_Sharp_Programming/Higher_Order_Functions#The_.7C.3E_Operator) 
- [OCaml](http://caml.inria.fr/pub/docs/manual-ocaml/libref/Pervasives.html#VAL%28|%3E%29)
- [Julia](http://docs.julialang.org/en/release-0.4/stdlib/base/?highlight=%7C%3E#Base.%7C%3E)
- [Elm](https://edmz.org/design/2015/07/29/elm-lang-notes.html)
- [LiveScript](http://livescript.net/#piping)
- **UNIX pipes**/Shell Script

Taking a look at a few examples, our very first one - incrementing and 
afterwards squaring a value, we would have something like this:

```swift
let myValue: Int = 66

let myNewValue: Int = myValue
                |> increment
                |> square
```

In our grades data manipulation example, we would get something like:

```swift
let finalGrades = Database.allStudents()
                  |> Grades.forStudents
                  |> curve(average: 0.6)
                  |> prepareGrades
```

Last but not least, our 3rd example - which involved *deep* optional chaining -,
after the **Pipe-Forward** operator goes like:

```swift
let imageURLString: String = "https://avatars2.githubusercontent.com/u/10639145"

let imageView = imageURLString
    |> { URL(string: $0) }
    |> { NSData(contentsOf: $0 as URL) }
    |> { UIImage(data: $0 as Data) }
    |> { UIImageView(image: $0) }
```

In summary, with the **Pipe Operator** it becomes incredibly more enjoyable
and readable to work with and shifts our way of thinking into making small
functions in linked chains.

## Detailed design

Basically, this:

```fsharp
x |> f
```

is equivalent to this:

```fsharp
f(x)
```

And this:

```fsharp
x |> f |> g |> h
```

is equivalent to this:

```fsharp
h(g(f(x)))
```

Since it's about just syntactic sugar, it can be defined as an operator in 
Swift like this:

```swift
infix operator |> { associativity left }
```

- `infix` because the operator must be used between left and right operands - e.g.
`==`.

- `associativity left` is because the data is transformed left-to-right.

As of **Swift 3**, with its 
[**improved operator declarations**](https://github.com/apple/swift-evolution/blob/master/proposals/0077-operator-precedence.md),
it can be defined as follows:

```swift
precedencegroup ForwardPipelining {
    associativity: left
}

infix operator |> : ForwardPipelining
```

The operator definition itself is not enough, we need to provide an 
implementation for it. 

> Generic types are not constrained, because that would limit the operator to
only work with specialized functions.

A simple implementation would be like:

```swift
func |> <T, U>(value: T, function: ((T) -> U)) -> U {
    
    return function(value)
    
}
```

By adding a layer of safety - doing *nil-checks*, with a little help from
optionals -, we get something like:

```swift
func |> <T, U>(left: T?, function: (T) -> (U?)) -> U? {
    
    if let value = left {
        return function(value)
    } else {
        return nil
    }
    
}
```

### Extra Operators Involved

#### **Pipe-Backward** Operator (`<|`)

The **Pipe-Backward** operator does exactly the opposite: takes a function on
the left and applies it to a value on the right:

```fsharp
x <| f <| g <| h
```

Although it seems to be unnecessary, the pipe-backward operator has an important
purpose in allowing the developer to easily change the operator precedence.

Its implementation follows the same logic behind the `|>` one.

> It is also important to notice that it would be part of a new 
`precedencegroup` - called `BackwardPipelining` - with `right` associativity.

#### **Tuple-Based** Operators (`||>`, `|||>`, `<||`, `<|||`)

There are also more four operators which end up being in the very same scope
of the first two ones:

##### `||>`

This one passes the tuple of two arguments on the left side to the function on
the right side.

It can be signed as: `( ||> ) : 'T1 * 'T2 -> ('T1 -> 'T2 -> 'U) -> 'U`. And 
used like this: `(arg1, arg2) ||> func`.

Its implementation could be as follows - since 
[implicit tuple splat behavior from function applications was removed](https://github.com/apple/swift-evolution/blob/master/proposals/0029-remove-implicit-tuple-splat.md#remove-implicit-tuple-splat-behavior-from-function-applications):

```swift
infix operator ||> : ForwardPipelining

func ||> <T1, T2, U> (left: (T1,T2), right: (T1, T2)->U ) -> U {
    return right(left.0, left.1)
}
```

##### `|||>`

Much like the previous one, this applies a function to three values - the values
being a triple on the left, the function on the right.

It can be signed as: `( |||> ) : 'T1 * 'T2 * 'T3 -> ('T1 -> 'T2 -> 'T3 -> 'U) -> 'U`. 
And used like this: `(arg1, arg2, arg3) |||> func`.

Its implementation goes like:

```swift
infix operator |||> : ForwardPipelining

func |||> <T1, T2, T3, U> (left: (T1,T2,T3), right: (T1, T2, T3)->U ) -> U {
    return right(left.0, left.1, left.2)
}
```

##### `<||`

Takes care of passing the tuple of two arguments on the right side to the 
function on left side.

It can be signed as: `( <|| ) : ('T1 -> 'T2 -> 'U) -> 'T1 * 'T2 -> 'U`. And 
used like this: `func <|| (arg1, arg2)`.

Implementation:

```swift
infix operator <|| : BackwardPipelining

func <|| <T1, T2, U> (left: (T1,T2) -> U, right: (T1,T2) ) -> U {
    return left(right.0, right.1)
}
```

##### `<|||`

The last one takes a tuple of three arguments on the right side to the function
on left side.

It can be signed as: `( <||| ) : ('T1 -> 'T2 -> 'T3 -> 'U) -> 'T1 * 'T2 * 'T3 -> 'U`. 
And used like this: `func <||| (arg1, arg2, arg3)`.

Implementation:

```swift
infix operator <||| : BackwardPipelining

func <||| <T1, T2, T3, U> (left: (T1,T2,T3) -> U, right: (T1, T2, T3) ) -> U {
    return left(right.0, right.1, right.2)
}
```

## Source compatibility

This is a new feature - basically, syntax sugar -, so there should be no major 
impacts on existing code.

Existing third party code which take advantage of overloading the new proposed
operators (`|>`, `||>`, `|||>`, `<|`, `<||`, `<|||`) - much likely for the very
same purpose - would receive *migration warnings* using a simple `Fix It`.

## Effect on ABI stability

Purely syntactic changes rarely change existing ABI. Neither does this one.

## Effect on API resilience

API resilience describes the changes one can make to a public API
without breaking its ABI. Does this proposal introduce features that
would become part of a public API? If so, what kinds of changes can be
made without breaking ABI? Can this feature be added/removed without
breaking ABI? For more information about the resilience model, see the
[library evolution
document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
in the Swift repository.

## Alternatives Considered

### Coding Your Custom Operators

By simply doing the three steps to define a custom operator:

- Naming it;

- Choosing a type;

- Assigning precedence and associativity.

And implementing the required functions to handle data pipeline, we could 
achieve the same behavior - and that is how the community has been using it.

However, this can be dangerous:

- Code with the very same purpose end up having different behavior
cross-projects.

- Simple changes in the way we do operator overloading - e.g. 
[`SE-0077`](https://github.com/apple/swift-evolution/blob/master/proposals/0077-operator-precedence.md) - would make those need to be rewritten ou result
in unexpected behavior.

### Using Libraries

This alternative is based on the use of libraries like:

- [Pipes](https://github.com/jarsen/Pipes);

- [Pipe](https://github.com/danthorpe/Pipe).

Those do the same overloading process under-the-hood and offer a simple *API* -
which usually comes also with other commom functions from 
*functional programming* toolbelts.

However, they have the same issues mentioned above and come with an aggravating
factor: **to fix the issue the developer relies on third-party code maintenance**.

## References & Further Reading

### Previous **Swift** Community Takes

#### Blog Posts

- [F#'s Pipe-Forward Operator in Swift](http://undefinedvalue.com/2014/07/13/fs-pipe-forward-operator-swift);

- [Function Composition & Pipelining Operators in Swift](https://vperi.com/2014/06/05/function-composition-pipelining-in-swift/);

- [Implementing a Custom Forward Pipe Operator for Function Chains in Swift](https://blog.mariusschulz.com/2014/09/13/implementing-a-custom-forward-pipe-operator-for-function-chains-in-swift);

- [Swift Data Pipelines](http://jasonlarsen.me/2015/05/23/pipes.html)

- [The Amazing Pipe Operator](http://danthorpe.me/posts/pipe.html);

- [Writing a pipeline operator in Swift](http://gilesvangruisen.com/writing-a-pipeline-operator-in-swift/).

#### On Github

- [Pipes](https://github.com/jarsen/Pipes);

- [Pipe](https://github.com/danthorpe/Pipe).

### Other Languages Community Takes

#### On Github

- [es-pipeline-operator](https://github.com/mindeavor/es-pipeline-operator)
for **JavaScript**;

- [Chainable Methods](https://github.com/akitaonrails/chainable_methods) for 
**Ruby**;

- [Pipeline operator proposal for PHP 7](https://github.com/haskellcamargo/php7-pipeline-operator-proposal)
for **PHP**;
