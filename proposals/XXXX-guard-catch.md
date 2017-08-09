# Introducing Guard-Catch

* Proposal: SE-TBD
* Author(s): [Soroush Khanlou](http://github.com/khanlou), [Caleb Davenport](caleb@calebd.me)
* Status: tbd
* Review manager: tbd

## Introduction

This proposal introduces a `guard`/`catch` statement to Swift. This statement is congruent to the existing `guard`/`else` statement while adding error catching support.

*This proposal was first discussed on the Swift Evolution list in the [[Pitch] Guard/Catch](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170703/037896.html) thread.*

## Motivation

Swift's native error handling mechanisms are powerful and convenient when the user works in a throwing context, such as functions and closures that can throw. Outside a throwing context, the user's only recourse is to use Swift's `do`/`catch` syntax to catch, pattern match, and handle thrown errors. 

The following example demonstrates the do-catch structure, demonstrating a critical gotcha with this syntax. Users must bind new symbols within the `do`-clause, causing code to nest one level deeper:

```
func nonThrowingFunction() {
    do {
        let value = try throwingFunction()
        // use `value`
    } 
    catch {
        // handle `error`
    }
    // `value` can not be used here, because the scope in which `value` is created has been left
    // any work that requires `value` must be done inside the `do` block
}
```

To avoid deeper nesting, users can apply the `try!` and `try?` operators, which either trap or discard the error. Neither option offers direct error handling. The user must sacrifice error information for succinct syntax.

Fortunately, Swift offers an existing language construct to guarantee  succesful conditions while handling the case where these fail. Introducing `guard`/`catch` will allow you to retrieve a value from a throwing call and handle any failure without discarding error information and or disrupting the [happy path](https://en.wikipedia.org/wiki/Happy_path) of a function.

## Design

The `guard`/`catch` statement is similar to the `guard`/`else` grammar. It substitutes a `catch` clause for `else`, which behaves like a standard `catch` clause, but as with `guard`/`else`, the `catch` clause must exit the scope after handling the error.

### In A Non-Throwing Function

In a non-throwing context, thrown errors are implicitly bound to `error` within the `catch` clause:

```
func nonThrowingFunction() {
    guard let value = try throwingFunction() 
        catch { 
            // handle `error` here, then leave scope
            print(error) // for example
            return 
        }
    // use `value` here
}
```

The catch clause can't rethrow this error because `nonThrowingFunction()` is not a throwing context. A similar theme occurs in non-throwing dispatch clauses.

### Pattern Matching And Error Names

The `catch` clause will support pattern matching and binding errors to names other than `error` like other `catch` clauses:

```
guard let value = try throwingFunction() 
    catch let someError as ErrorType1 {
        // only triggered when someError is of type ErrorType1
    } 
    catch let error as ErrorType2 {
        // only triggered when someError is of type ErrorType2
    } 
    catch let catchAllError {
        // catches all errors that weren't caught elsewhere
    }
```

### Binding Variable References

Like a `guard`/`else` statement, values can be bound to `var` as well as `let` symbols. `var` references can be mutated in the enclosing scope.

```
guard var array = try throwingFunction() catch { return }

// `array` can be both used or mutated here
```

### Non-Leading Try

As with the existing `try` operator in the language, it doesn't need to be used in the first position in the expression. 

```
guard let x = foo(try bar()) catch { return }
```

### Binding Multiple Variables

As with `guard`/`else`, multiple let bindings are allowed:

```
func nonThrowingFunction() {
    guard
        let value = try throwingFunction(),
        let secondValue = try secondFunction(with: value)
        catch let error {
            // handle error here, then leave scope
            print(error)
            return
        }
    // both secondValue and value can be used here
}
```

Each separate binding needs its own `try` and throwing function to be valid.

### Throwing Functions That Return Void

`guard`/`catch` can also be used for side-effect-inducing functions that throw an error, but don't return a value:

```
guard try model.save() catch {
	return
}
```

These can be mixed and matched with expressions that do return values and result in binding new variables.

## Impact on Existing Code

This change is purely additive.

## Alternatives Considered

**Extend the existing `guard`/`else` construct for errors**. In Swift, it is legal to write a function that can _both_ throw and return an optional. Although this is not an ideal function signature, it is expressible. It may creep into a code path through optional chaining. Calling a throwing function on an optional value will result in either an optional or an error:

```
try optionalValue?.throwingFunction()
```

A combination `guard` could handle this like so:

```
guard let value = try optionalValue?.throwingFunction() 
    catch {
        // handle errors
    }
    else { 
        // handle nil
    }
```

This raises a few questions: 

* Does the presence of the `else` clause implicitly change the type of `value` from an optional to a non-optional? 
* Is there any prescription on the order of the clauses? 
* Can an `else` appear between two pattern-matching `catch` clauses? 

For both implementation and cognitive simplicity, the authors of this proposal recommend `guard`/`catch` and `guard`/`else` be considered as completely separate units.

There is a second reason to disallow interplay between `guard`/`else` and `guard`/`catch`. In Swift, it is straightforward to lift the `.none` case of an optional to an error. Eliding a few niceties (like storing the `#file` and `#line` in the error), this can be done like so:

```
struct NilError: Error { }

extension Optional {
    func unwrap() throws -> Wrapped {
        guard let result = self else { throw NilError() }
        return result
    }
}
```

While inclusion of this extension into the standard library is beyond the scope of this proposal, adding it to a project is easy. It enables bridging an expression that can either return both an optional and throw an error into an expression that _only_ throws an error.

```
guard let value = try optionalValue.unwrap().throwingFunction() 
    catch { 
        // might be NilError, might be any of the original errors from the function
        return 
    }
```

Pattern matching can be used to handle the `NilError` case separately from the other errors.

**Omitting the `guard` keyword.**


```
let value = try throwingFunction() catch { 
    print(error)
    return 
}
// ...
```

This alternative was proposed on the the Swift Evolution mailing list. The authors reject this, because without a `guard` keyword, it's less obvious that the user must exit the scope, and without exiting the scope, `value` would have to be bound as an optional, defeating the purpose of this proposal.

**Requiring `else` before the `catch` keyword.**

For example:

```
guard let value = try throwingFunction() else catch { 
    // `error` is already bound here, without a `let`
    print(error)
    return 
}
// ...
```

While this does read nicely, `else` adds noise without syntactical benefit. It is closer to the `guard`/`else` syntax, leading to potential confusion.

**Implicitly binding the `error` variable in the existing `guard`/`else` statements.**

```
guard let value = try optionalValue?.throwingFunction() 
    else {
        // `error` here is of type `Error?` and exists in every `guard try`/`else`
        print(error)
        return // or re-throw error
    }
```

This should be rejected. It subtly alters the flow of existing code, as seen below:

```
func nonThrowingFunctions() throws {
    guard let value = try input.funcThatReturnsAnOptional() 
        else {
            throw MyError.implementationFlaw
        }
    
    // compute with value
}
```

In this example, errors thrown by `funcThatReturnsAnOptional()` are implicitly swallowed and replaced with `MyError.implementationFlaw`.