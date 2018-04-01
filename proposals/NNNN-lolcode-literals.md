# `#lolcode` Literals or: How Swiftc Learned to Stop Typechecking and Love Dynamic Code
* Proposal: [SE-NNNN](NNNN-lolcode-literals.md)
* Authors: [Robert Widmann](https://github.com/codafi), [Harlan Haskins](https://github.com/harlanhaskins)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

We propose facilities for modern dynamic programming in the Swift programming language.  To accomplish this
we introduce new syntax for the creation of dynamic code, and new runtime support in the Swift Standard
Library to match.  With these changes, we hope to finally and totally address a long-standing criticism of
the Swift programming language.

## Motivation

Since its inception, Swift has been criticized for adopting strong static typing despite having interoperability with
legacy dynamic and weakly typed language code. Many have expressed frustration over this lost dynamism, and have
called for Swift to be summarily extended to support more dynamic features. We intend to satisfy that overwhelming 
demand (and more) by introducing support for modern dynamic programming that complements and extends Swift.

Dynamic code is hailed by its supporters as being quicker to write, easier to read, and much more immediately gratifying 
to program with than static code.  Popular dynamic languages like JavaScript and PHP are prime examples of this style of
thinking - and we believe, as do the aforementioned critics of Swift, that these languages [are](https://bugs.php.net/bug.php?id=55439) 
[perfect](https://dorey.github.io/JavaScript-Equality-Table/) [in](https://groups.google.com/forum/#!forum/rubyonrails-security) 
[every](https://gts3.org/assets/papers/2013/chen:vmsec-slides.pdf) [way](https://en.wikipedia.org/wiki/ActionScript), and that they
should stand as a model for all other languages.  To that end, we propose the fusion of Swift's current (backwards)
static approach with a forward-thinking dynamic approach.

[LOLCode](lolcode.org) is a modern, imperative, dynamic programming language widely regarded as the natural
successor to SmallTalk. Its consistent syntax and cheerful outlook on programming inspire confidence
in even beginner users, and its support for interoperability with C make it a natural target for
low level systems programming for advanced users.

## Proposed solution

We intend to add a new magic literal, `#lolcode(…)` - whose syntax and usability ethos are directly inspired by
the glorious minds that worked to include [annex J](http://www.open-std.org/jtc1/sc22/wg14/www/docs/n1256.pdf) 
in the ISO C and C++ standards.  The `#lolcode` literal shall begin a new anonymous LOLCode function into which
LOLCode code may be written directly.  LOLCode code in the `#lolcode` literal is directly executable and may accept 
values from Swift code as well as return values to Swift code.

```swift
var prod = 1
let n = 10
let factorial = #lolcode(
  IM IN YR LOOP UPPIN YR i TIL BOTH SAEM i AN n
    prod R PRODUKT OF prod AN SUM OF i AN 1
  IM OUTTA YR LOOP
  FOUND YR prod
)
```

```swift
#lolcode(
  I HAZ A z
  I HAZ A x
  x R 6
  z R SUM of x and 76
  VISIBLE z BTW prints ’82’
)
```

To support LOLCode as a first class citizen, the compiler shall be changed to accept any file
with the extension `.lol` as LOLCode and shall compile it to a form compatible with any other
Swift code.  All functions defined in LOLCode shall be available to other Swift files in the module, 
and all declarations have  shall have `public` access.  All necessary Swift functions shall similarly
be available to LOLCode, and be directly callable using native `I IZ <function> YR <arguments> MKAY`
syntax.

To our knowledge, this will make Swiftc the world's first optimizing compiler for LOLCode, and the world's first
complete LOLCode-to-LLVM compiler.

## Detailed design

Upon seeing a `#lolcode` literal in expression position, the parser will parse the
LOLCode into a Swift closure that will be automatically called. These closures
have type `() -> Any`, and (strongly) capture variables from outer scope.  

Note that LOLCode's "Type System" defines `NOOB` (Void), `NUMBR` (Integer), 
`NUMBAR` (Double), `YARN` (String), `TROOF` (Bool), and `BUKKIT` (Array<Any>),
values of other types will be converted to the appropriate LOLCode type, according to the
following mappings:

| Swift type | LOLCode type
| --- | ---
| \[U\]Int\[8/16/32/64\] | NUMBR (cast to Swift Int)
| Float/Double/Float80 | NUMBAR (cast to Swift Double)
| String/All other types | YARN (converted to String using string interpolation behavior)
| Array<Any> | BUKKIT (all inner values recursively converted to LOLCode equivalents)
| Void | NOOB
| Bool | TROOF

LOLCode constructs will be parsed into their equivalent Swift constructs.  An example of this
mapping is given below:

| LOLCode | Equivalent Swift
| --- | ---
| I HAZ A <name> | var <name>: Any
| <name> R <expr> | <name> = <expr>
| FOUND YR <expr> | return <expr>
| SUM OF lhs AN rhs | _lolcode_sum(lhs, rhs)
| PRODUKT OF lhs AN rhs | _lolcode_product(lhs, rhs)
| QUOSHUNT OF lhs AN rhs | _lolcode_quotient(lhs, rhs)
| DIFF OF lhs AN rhs | _lolcode_diff(lhs, rhs)
| MOD OF lhs AN rhs | _lolcode_mod(lhs, rhs)
| BOTH SAEM lhs AN rhs | _lolcode_both_saem(lhs, rhs)
| DIFFRENT lhs AN rhs | _lolcode_diffrent(lhs, rhs)
| BOTH OF lhs AN rhs | _lolcode_both_of(lhs, rhs)
| EITHER lhs AN rhs | _lolcode_either(lhs, rhs)
| VISIBLE expr | print(expr)
| SMOOSH expr... | _lolcode_smoosh(expr...)
| GIMMEH lhs | lhs = _lolcode_gimmeh()
| MAEK expr A type | _LOLCodeValue(expr).cast(to: .type).value
| VISIBLE expr ! | print(expr, terminator: “”)

  
The Swift Standard Library shall be modified with support for the LOLCode runtime and builtin operations.  A model implementation
of a generic LOLCode value and the complete type system of LOLCode is given as follows:

```swift
public enum _LOLCodeType: String {
  case yarn, numbar, numbr, noob, bukkit, troof

  var defaultValue: _LOLCodeValue {
    switch self {
    case .bukkit: return .bukkit([])
    case .noob: return .noob
    case .numbar: return .numbar(0.0)
    case .numbr: return .numbr(0)
    case .troof: return .troof(false)
    case .yarn: return .yarn("")
    }
  }
}

public enum _LOLCodeValue: Equatable {
  case yarn(String)
  case numbar(Double)
  case numbr(Int)
  case noob
  case bukkit([_LOLCodeValue])
  case troof(Bool)

  public static func == (lhs: _LOLCodeValue, prerhs: _LOLCodeValue) -> Bool {
    switch (lhs, rhs) {
    case let (.yarn(l), .yarn(r)): return l == r
    case let (.numbar(l), .numbar(r)): return l == r
    case let (.numbr(l), .numbr(r)): return l == r
    case let (.numbar(l), .numbr(r)): return l == Double(r)
    case let (.numbr(l), .numbar(r)): return Double(l) == r
    case (.noob, .noob): return true
    case let (.bukkit(l), .bukkit(r)): return l == r
    case let (.troof(l), .troof(r)): return l == r
    default: return false
    }
  }

  var _type: _LOLCodeType {
    switch self {
    case .yarn(_): return .yarn
    case .numbar(_): return .numbar
    case .numbr(_): return .numbr
    case .noob: return .noob
    case .bukkit(_): return .bukkit
    case .troof(_): return .troof
    }
  }

  var value: Any {
    switch self {
    case .yarn(let s): return s
    case .numbar(let d): return d
    case .numbr(let i): return i
    case .noob: return ()
    case .bukkit(let arr): return arr.map { $0.value }
    case .troof(let b): return b
    }
  }

  func cast(to type: _LOLCodeType) -> _LOLCodeValue {
    guard self._type != type else {
      return self
    }

    switch (self, type) {
    case (_, .troof): return .troof(asTroof)
    case (_, .yarn): return .yarn("\(self.value)")
    case (.noob, let ty): return ty.defaultValue
    case let (.numbr(n), .numbar): return .numbar(Double(n))
    case let (.numbar(d), .numbr): return .numbr(Int(d))
    case let (.yarn(s), .numbar):
      guard let d = Double(s) else { break }
      return .numbar(d)
    case let (.yarn(s), .numbr):
      guard let i = Int(s, radix: 10) else { break }
      return .numbr(i)
    case let (.troof(b), .numbr): return .numbr(b ? 1 : 0)
    case let (.troof(b), .numbar): return .numbar(b ? 1 : 0)
    default: break
    }
    fatalError("i cant maek '\(self)' in2 a '\(type.rawValue)'")
  }

  var asTroof: Bool {
    switch self {
    case .yarn(let s):
      return s.contains("t") || s.contains("y") || s.contains("1")
    case .numbar(let n): return n != 0
    case .numbr(let n): return n != 0
    case .troof(let b): return b
    case .noob, .bukkit: return false
    }
  }

  init(_ value: Any) {
    switch value {
    case is Void:
      self = .noob
    case let value as _LOLCodeValue:
      self = value
    case let value as String:
      self = .yarn(value)
    case let value as Int:
      self = .numbr(value)
    case let value as Double:
      self = .numbar(value)
    case let value as Bool:
      self = .troof(value)
    case let value as [Any]:
      self = .bukkit(value.map(_LOLCodeValue.init))
    case let value as UInt8:
      self = .numbr(numericCast(value))
    case let value as UInt16:
      self = .numbr(numericCast(value))
    case let value as UInt32:
      self = .numbr(numericCast(value))
    case let value as UInt64:
      self = .numbr(numericCast(value))
    case let value as Int8:
      self = .numbr(numericCast(value))
    case let value as Int16:
      self = .numbr(numericCast(value))
    case let value as Int32:
      self = .numbr(numericCast(value))
    case let value as Int64:
      self = .numbr(numericCast(value))
    case let value as UInt:
      self = .numbr(numericCast(value))
    case let value as Float:
      self = .numbar(Double(value))
    case let value as Float80:
      self = .numbar(Double(value))
    default:
      self = .yarn("\(value)")
    }
  }
}
```

Because LOLCode maps directly to the Swift AST, no changes to the type system and very minimal changes 
to codegen are needed to support the entire language. 

## Source compatibility

This is a purely additive change. The only way it could impact source compatibility would be if LOLCode 
compiled in a former version of Swift, and we were really quite thorough about silencing viable competition
and well-meaning naysayers. 

EDIT: After publication, the authors have, in fact, identified a previous Swift proposal under which LOLCode
constructs have made it into the language. We are deeply annoyed that the proposal in question has chosen the name
"Access Control" to mask this fact.

## Effect on ABI stability

The ABI Is Strong And Stable.

## Effect on API resilience

LOL

## Alternatives considered

In order for alternatives to have been considered, viable alternatives would have to *exist*.  There simply is no dynamic language
invented up to or before this point in time that could possibly support the march of Swift towards its inevitable dynamic future that is
not LOLCode.  
