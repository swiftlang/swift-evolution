# Improved and Categorizing Compiler Error Messages

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Genaro-Chris](https://github.com/Genaro-Chris)
* Review Manager: TBD
* Status: **Awaiting implementation** or **Awaiting review**
* Review: ([Pitch](https://forums.swift.org/...))

## Introduction

Currently the Swift compiler error messages aren't really helping convene the true problem encountered during compilation. Sometimes either the message displayed by the compiler are sometimes generic or not helpful in trying to aid the programmer correct him or herself, or errors hard to recreate in a different context or situation. This often leads to quick dismay of our sweet language by some new developers coming from other languages.

```
struct Person {
    let name: String
    let age: UInt
}

let adam = Person(name: "Adam", age: 18)
adam.walk()
```
When the above code compiles, the compiler error would be

```
error: value of type 'Person' has no member 'walk'
adam.walk()
```

## Motivation

 This proposal would help categorize error messages, explain the cause of the error and possibly with code examples, ways of preventing or correcting such errors from recurring.
 
## Proposed solution

Taking similar routes as some other languages such as Rust or C# as such languages as grouped error messages into some sort of error message index for easy referencing, tips for prevention and quick look-ups.

Example with that of C# language

```
using System;

public class Program
{
	public static void Main()
	{
		var john = new Person("John Adam", 18);
		john.walk();
		Console.WriteLine("Hello World");
	}
}

public class Person {
	string name;
	uint age;
	public Person(string name, uint age) {
		this.name = name;
		this.age = age;
	}
}
```
If the preceding code is compiled, the error message would be

```
Compilation failed: 1 error(s), 0 warnings

HelloWorld.cs(8,8): error CS1061: Type `Person' does not contain a definition for `walk' and no extension method `walk' of type `Person' could be found. Are you missing an assembly reference?
HelloWorld.cs(13,14): (Location of the symbol related to previous error)
```
The error codes is hosted online at [C# Compiler message](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-messages/).


While that of Rust language

```
fn main() {
    struct Person {
        name: String,
        age: i8,
    }
    let adam = Person {
        name: String::from("Adam"),
        age: 18,
    };
    adam.walk();
}
```
If the preceding code is compiled, the error message would be

```
error[E0599]: no method named `walk` found for struct `Person` in the current scope
 --> src/main.rs:9:10
  |
1 | struct Person {
  | ------------- method `walk` not found for this struct
...
9 |     adam.walk();
  |          ^^^^ method not found in `Person`

For more information about this error, try `rustc --explain E0599`.
```
The error code index is hosted online at [Rust error codes index](https://doc.rust-lang.org/error_codes/error-index.html)

## Detailed design

Still using our Swift example, the error should look like this instead

```
Found error SE0157: value of type 'Person' has no member 'walk
		adam.walk()
		~~~ ^ ~~~
		       
For more information about this error, try swiftc --describe SE0157	
```
Also using a new compiler flag 'describe', we could reference the preceding error category

>__$swiftc describe SE0157__

The following would be the output

```
This error occurs when a method is used on a type which doesn't implement it:

Error:
struct Example {}

let x = Example()
x.exampleMethod(); // error: no method named `chocolate` found for type `Mouth`in the current scope

Fix-it: 
In this case, you need to add the implementation of `exampleMethod` method to fix the error:

struct Example { 
  func exampleMethod() {
    print("Example struct method named \(#function)")
  }
}

let x = Example();
x.exampleMethod(); // ok!
```
Then the compiler error messages would be hosted on the [Swift language](https://www.swift.org) similar to those of Rust and C# languages.

## Source compatibility

This is compatible with all Swift versions

## Effect on ABI stability

This has no effect on ABI stability since it is additive

## Effect on API resilience

This has no effect on API resilience since it is additive 

## Alternatives considered

We could continue with the current implementation

## Acknowledgments

To all Swift developers over the world in one way or the other trying to make it a better language than it was yesterday.


