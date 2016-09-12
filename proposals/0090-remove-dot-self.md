# Remove `.self` and freely allow type references in expressions

* Proposal: [SE-0090](0090-remove-dot-self.md)
* Authors: [Joe Groff](https://github.com/jckarter), [Tanner Nelson](https://github.com/tannernelson)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Deferred**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000174.html)
* Revision: 2

## Introduction

Swift's grammar currently requires that type references only appear as part of
a constructor call `T(x)` or member access `T.x`. To get the metatype object
for `T`, one must refer to the special member `T.self`. I propose allowing
type references to appear freely in expressions and removing the `.self` member
from the language.

Swift-evolution thread: [Making `.self` After `Type` Optional](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012239.html)

## Motivation

The constructor-or-member restriction on type references exists to provide
grammatical and semantic disambiguation between type references and other
expressions:

- Like C++, Java, and C#, Swift adopts angle bracket syntax for generic
  parameters, `T<U>`. In expression contexts, this introduces a grammar
  ambiguity with operators `<` and `>`. The expression `T<U>(x)` could be
  parsed either as a constructor call, `(T<U>)(x)`, or as a chain of
  comparisons, `(T<U)>(x)`. Rather than follow in C++'s footsteps of relying
  on name lookup to resolve the parse, which introduces ugly interdependencies
  between parsing and semantic analysis, Swift borrowed the heuristic
  grammatical approach taken by Java and C# to disambiguate these cases.
  When parsing an expression, when we see an identifier is followed by an
  opening angle bracket `T<`, we attempt to parse a **potential generic
  parameter list** using the type grammar, and if we reach a matching
  closing bracket `>`, we look at the following token.  If the token after `>`
  is `(`, `.`, or one of a few other **disambiguating tokens**, we accept the
  parse as a generic parameter list; otherwise, we backtrack and reparse the
  initial `<` as an infix operator.
  
    Though not formally perfect by any means, this heuristic approach works
    well because `a < b > c` is unlikely to begin with (and impossible in
    standard Swift, because `Bool` is not `Comparable` in the standard
    library), and `(a < b, c > (d))` is unlikely as a standalone tuple of
    expressions due to the already-low precedence of `>`.  Swift adds
    leading-dot `.member` expressions over Java and C#, so `(a < b, c > .d)` is
    a possibly semantically valid expression, but in practice this has never
    been reported as a problem.

- Swift reuses several expression forms as type sugar for common types:
  `T?` for `Optional<T>`, `[T]` for `Array<T>`, and `[T: U]` for
  `Dictionary<T, U>`. `(T, U, ...)` is also both the primitive syntax for
  tuple types and for tuple literals. Since bare type references are not
  currently allowed in expressions, this avoids conflicts between the type
  reference and expression forms; `[T].self` can only be a type reference to
  `Array<T>`, since a single-element array containing the type object for `T`
  has to be spelled `[T.self]`. (Note that this fails for `()`, which is
  both a valid type reference and expression.)

Though precedented by other languages (arguably including Objective-C, since
one can only indirectly message classes via `[Class method]` and cannot
reference a `Class` object directly), this constructor-or-member restriction
hasn't been a great fit for Swift, since Swift places a stronger emphasis on
type objects. Unlike Java or C#, Swift type objects are
first-class, strongly-typed "metatypes", and type objects are readily available
without having to go through obscure reflection APIs. Type objects can also be
used dynamically in polymorphic contexts via `class` methods and `static`
protocol requirements, as in Objective-C. Though similar to Objective-C's
`[T self]`, Swift's `T.self` syntax is frequently
criticized as obscure, and uglifies code that works heavily with type objects.
We should improve our heuristics for dealing with these ambiguities so that
`.self` becomes unnecessary.

## Proposed solution

I propose making the following changes:

- Augment the lookahead rule for parsing generic parameter lists in expressions,
  so that `T<U>` type references can be reliably parsed at arbitrary positions 
  within expressions.
- Treat the disambiguation of `T?`, `[T]`, and `[T: U]` as a contextual
  typing problem, favoring the type reference analysis if possible,
  but allowing type context to choose the array or
  dictionary literal interpretation.
- Remove the now nearly useless magic `.self` member from the language.

## Detailed design

### Disambiguating `T<U>`

To disambiguate `T<U>` in more expression positions, we can expand the set
of lookahead tokens we accept after a potential generic parameter list.
Let's enumerate the expression productions in which `T<U>` is likely to appear:

- As a top-level statement or variable binding, followed by a newline,
  semicolon, or enclosing `}`:

    ```swift
    _ = T<U>; let t = T<U> /* \n */

    let makeType: () -> Any.Type = { T<U> }
    ```

- In a ternary, followed by `:`:

    ```swift
    condition ? T<U> : V<W>
    ```
  
    or, less likely (if some creative developer in future Swift conformed
    metatypes to `BooleanProtocol`), as the condition followed by `?`:

    ```swift
    T<U> ? x : y
    ```

- On the LHS of a cast, followed by `is` or `as`:

    ```swift
    T<U> as Superclass.Type
    T<U> is Protocol.Type
    T<U> as? Protocol.Type
    ```

- As an element of a container literal, followed by `,`, `:`, or `]`:

    ```swift
    [T<U>, V<W>]
    [T<U>: V<W>]
    ```

- As a binding in a capture list, also followed by `]`:

    ```swift
    {[t = T<U>] in t }
    ```

- As an element of a tuple or argument list, followed by `,` or `)`:

    ```swift
    doStuff(withType: T<U>, andOtherType: V<W>)
    ```

- As the root of a constructor call or member access, followed by `(`, `.`, or
  `[`:

    ```swift
    T<U>(x: 1, y: 2)
    T<U>.staticMethod()
    T<U>[x] // maybe we'll have `static subscript` one day?
    ```

- As the operand of an operator, followed by a postfix or infix operator token:

    ```swift
    ++T<U>
    T<U>++
    T<U> + x
    T<U>+x
    ```

    Operators are interesting because they also potentially require special
    token-splitting behavior in the lexer to interpret `>+` as two tokens rather
    than a single operator name.

Potential ambiguities arise when `>` is followed by a token that can also
begin a new subexpression. This isn't a problem for many of the tokens
enumerated above; `,` `;` `:` `?` `}` `]` `)` `is` and `as` all unambiguously
terminate or continue the current expression and can be safely added to the
set of *disambiguating tokens*. Let's consider the potentially
ambiguous cases:

- **Newlines**: As the last production in an expression, `T<U>` may be followed
  by another statement or declaration on a new line. This is formally ambiguous
  with an expression involving `<` and `>` operators broken across lines:

    ```swift
    a < b >
    c
    ```

    However, as we noted before, `a < b > c` is not a semantically correct
    expression in standard Swift. Furthermore, Swift does not have a comma
    operator, so `a < b, c > d` is not a valid expression outside of a tuple,
    function call, or array literal. For these reasons, I propose that it's
    safe to say that **a potential generic parameter list whose closing angle
    bracket is followed by a token on a new line is parsed as a generic
    parameter list.**

    ```swift
    // Parses as generic param list `let foo = (a<b>); c`
    let foo = a<b>
    c
    // Parses as operator expr `let foo = (a<b)>c`
    let foo = a<b>c
    ```

- **Opening brackets**: Though we already include `(` among the set of
  *disambiguating tokens*, we do not include `[`. We do not currently
  support `static subscript` members, so this wouldn't be immediately useful.
  If we think that's something we may introduce in the future, we could
  consider adding `[` to the set of *disambiguating tokens*. The
  expression production `(a < b, c > [d])` is theoretically possible, if
  a function takes multiple unlabeled `Bool` arguments. This strikes me
  as slightly more likely than `(a < b, c > .d)` or `(a < b, c > (d))`,
  since array literals are more common than `.constant`s, and array literals
  don't have the precedence defense that obviates the need to write
  `(a < b, c > (d))`.

- **Operators**: Swift requires balanced whitespace around infix operators,
  which can disambiguate between a generic type as the left operand of a
  binary operator and a prefix operator as the right operand of `>`:

    ```swift
    a<b> + c  // (a<b>) + c
    a<b > +c  // (a<b) > (+c)
    ```

    I'm going to go out on a limb and say that's good enough. We could conceive
    of heroics to decide when to split operator tokens in the `a<b>+c` case, but
    in the standard library, the only operators that apply to type objects
    are `!=` and `==`, and while there are some developers who favor "Yoda
    conditionals" with the constant on the left, the `variable == T<U>` style
    with the constant on the right is more common.

In summary, I propose we keep the existing disambiguation rule for
generic parameter lists, but expand the list of *disambiguating tokens*
to include `.` `,` `;` `:` `?` `}` `]` `(` `)` `is` and `as`, spaced binary
operators, and any token on a new line. This should let us parse `T<U>` in
expression context reliably enough to eliminate the need for `.self` as a
grammatical disambiguator.

### Disambiguating type sugar syntax

The semantic problem of disambiguating type sugar from literal expressions can
be considered a contextual typing problem and handled during type checking. If
`x?`, `[x]`, `(x, y, ...)`, or `[x: y]` appear in a metatype type context, we
can attempt the type reference interpretation. If `x?` is applied to an
optional value `x`, or `[x]` appears in `ArrayLiteralConvertible` context, or
`[x: y]` appears in `DictionaryLiteralConvertible` context, then we attempt the
expression interpretation:

  ```swift
  func useType(_ type: Any.Type) {}
  func useArray(_ array: [Any.Type]) {}
  func useDictionary(_ dict: [Any.Type: Any.Type]) {}

  useType(Int?)          // Passes Optional<Int>
  useType([Int])         // Passes Array<Int>
  useType([Int: String]) // Passes Dictionary<Int, String>

  useArray([Int])         // Passes an array, containing Int
  useDictionary([Int: String]) // Passes a dictionary, mapping Int => String
  ```

The type reference interpretation should still only be valid when the sugar
syntax is applied to concrete type references, not metatype variables:

  ```swift
  let int = Int
  useType([int]) // Error, can't form type reference, and
                 // array literal doesn't type-check
  ```

If type context is not available, the compiler should reject a potentially
ambiguous expression:

  ```swift
  let x = [Int] // Error, could be either Array(Int) or Array<Int>
  print([Int])  // Likewise

  let int = Int
  let y = [int] // OK, not a type reference, evaluated as array containing
                // `int`
  ```

This should not usually be problematic, since type references are most
useful as function parameters, where type context is readily available.
The usual language mechanisms for providing context can be used to clear up
the ambiguity, such as providing explicit variable types or using `as` coercion,
can be used to pick the correct interpretation:

  ```swift
  let x1: Any.Type = [Int]   // [Int] is Array<Int>
  let x2: [Any.Type] = [Int] // [Int] is Array(Int)
  let x3 = [Int as Any.Type] // Another way to force array literal interp

  print([Int] as Any.Type)   // Prints the metatype
  print([Int] as [Any.Type]) // Prints the array
  ```

## Impact on existing code

If these heuristics are well-chosen, existing code should not be noticeably
affected by these changes, other than being liberated from the burdensome
`.self`s on type references. This is something we should verify experimentally
by compiling existing codebases with a compiler that implements these proposed
language changes.

## Alternatives considered

### Change syntax to eliminate the ambiguities

There are various fundamental things we could change in Swift's syntax to
eliminate the ambiguities from the language entirely, including:

- using different brackets for generic type parameters, e.g. `Array(Int)`
  or `Array[Int]`;
- making the `UppercaseTypes`, `lowercaseValues` convention a syntactic
  requirement, as is done in ML and Haskell.

These are directions we rejected early on in the development of Swift, since
we felt that maintaining familiarity with C-family languages was worth burning
some implementation complexity.

## Revision history

### May 26, 2016

A previous revision of this proposal offered a default disambiguation rule
for ambiguous type references without type context:

  ```swift
  let x = [Int] // binds x to the type object Array<Int>
  ```

In discussion, the core team decided it was preferable for ambiguous references
to be rejected by the compiler and require explicit context.
