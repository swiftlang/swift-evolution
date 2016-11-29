# typeprivate

Create **typeprivate** access control level

Proposal: SE-NNNN  
Author: [Gonçalo Alvarez](https://github.com/goncaloalvarez), [Álvaro Monteiro](https://github.com/amsmonteiro)  
Status: **Proposed**  

## Introduction
Access control modifiers are one of the cornerstones of Swift programming practices. They should be handled with great care. As a developer, one should dodge the path of massifying files with code whose responsible entity is the **Type** owning the file's real estate. Extensions do help in scoping the code and creating private contexts for better code structruing and readability. Extensions placed on another file should be able to access private members of such Type whenever they are **typeprivate**. 

## Motivation
As a developer, it is a good practice to create extensions for *protocol compliance*, *private methods*, *public methods*, and code with a very clear and related responsability within the Type it belongs to.  
It is also a good common practice to extend a Type's behaviour on separate files, either out of respect for context, or simply to improve code readability by reducing the size of the source file.  
However, this raises an issue on accessing members of the *Reference Types* or *Value Types* whose access control modifier is more restrictive than *internal*, thus making it impossible to access or modify a *fileprivate* (and *private*) member on an extension placed other than within the source file for the Type in question. In fact, we believe there's too big a gap between this access control modifier and the one that follows in order of restrictiveness *fileprivate*.

**Case one**

```Swift 
//MyType.swift

struct MyType {
    
    var propertyOne = 1
    fileprivate var propertyTwo = 2
    private var propertyThree = 3
}

extension MyType {
    
    mutating func mutate() {
        
        self.propertyOne = 10
        self.propertyTwo = 20
        self.propertyThree = 30
    }
}

```
Trying to mutate *propertyThree* raises an error as expected, since this we're trying to access a member whose level allows only for access within implementation context

```Swift
//MyTypeExtended.swift

extension MyType {

    mutating func mutateFurther() {
    
        self.propertyOne = 100
        self.propertyTwo = 200
    }
}
```
Trying to mutate *propertyTwo* raises an error, since this we're trying to access a member whose level allows only for access within the same file. This the error we are trying to avoid.


**Case two**

```Swift
//MyViewController.swift

class MyViewController: UIViewController {

    fileprivate var gestureRecognizer = UIGestureRecognizer()
    ...
}
```

This example portrays a common yet cumbersome issue to a developer's every day life: gesture recognizer and how large the code can grow while handling the gesture. Also, it is very common for the gesture handling code to try to access other members that, for the sakes of good programming practices, are prone to have a restrictive access level as well.  
Case in point: feeling the urge to port the related code to a separate file extending the view controller.

```Swift
//MyViewControllerExtended.swift

extension MyViewController {

    func setup() {

        self.gestureRecognizer.addTarget(target: self, action: #selector(MyViewController.handleGesture(_:)))
        self.view.addGestureRecognizer(self.gestureRecognizer)
    }
}

//MARK: - GestureHandling

extension MyViewController {

    func handleGesture(_ gestureRecognizer: UIGestureRecognizer) {
    
        //Handle the gesture.
        //Most likely try to access fileprivate or private members as well
    }
}
```
Doing this would raise an error, since *gestureRecognizer* is a **fileprivate** member, whose access is not made available on a separate file.

## Proposed solution
Allowing for the **typeprivate** access control modifier to fill in this gap, thus enabling members, whose access should not be internal, to be accessed on extensions placed some file else than the source file for a given Type.  
The proposed list of access control modifiers:  

* **open**
* **public**
* **internal**
* **typeprivate**
* **fileprivate**
* **private**


***Changes to the code in Case one***

```Swift
//MyType.swift

struct MyType {
    
    var propertyOne = 1
    typeprivate var propertyTwo = 2
    private var propertyThree = 3
}

extension MyType {
    
    mutating func mutate() {
        
        self.propertyOne = 10
        self.propertyTwo = 20
        self.propertyThree = 30
    }
}

```
Trying to mutate *propertyThree* would obviously still raise an error, since this we're trying to access a member whose level allows only for access within implementation context

```Swift
//MyTypeExtended.swift

extension MyType {

    mutating func mutateFurther() {
    
        self.propertyOne = 100
        self.propertyTwo = 200
    }
}
```

Trying to mutate *propertyTwo* would **no longer** raise an error, since *typeprivate* would allow for this property to be accessed from within every extension of *MyType* even if placed on file other than *MyType.swift*.

***Changes to the code in Case two***

```Swift
//MyViewController.swift

class MyViewController: UIViewController {

    typeprivate var gestureRecognizer = UIGestureRecognizer()
    ...
}

//MyViewControllerExtended.swift

extension MyViewController {

    func setup() {

        self.gestureRecognizer.addTarget(target: self, action: #selector(MyViewController.handleGesture(_:)))
        self.view.addGestureRecognizer(self.gestureRecognizer)
    }
}

//MARK: - GestureHandling

extension MyViewController {

    func handleGesture(_ gestureRecognizer: UIGestureRecognizer) {
    
        //Handle the gesture.
    }
}
```

Trying to access *gestureRecognizer* would **no longer** raise an error, since *typeprivate* would allow for this property to be accessed from within every extension of *MyViewController*.  
This would definitely result in better code readability and smaller files.

## Impact on existing code
 
This change to the levels of access control modifiers is strictly additive, and does not break any existing code. It purely makes room for a more detailed specification of the access control each type member should have.

## Alternatives considered

This solution may endure opposition while we do understand that adding a new level to the existing 5 levels of access control is prone to have developers deem this solution as somehow overengeneering and overcomplex.  
Should this be the case, then **typeprivate** could replace **fileprivate** in the list of modifiers, since both their levels are the ones that relate the most in terms of access privilege. Every *fileprivate* member would still be accessible from within all extensions whether they are placed within the file, or in another one.
