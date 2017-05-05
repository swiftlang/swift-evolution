#Protocol Function Implementation Clearity

##Introduction

This proposal provides clear and easy way to reach protocol functions and helps implementation.

##Readability

Current implementation of the methods that are related to protocols are no different from the plain function that is also used in your class.

But protocol functions bear importance in the project more than the plain functions and needs to be more bold in the context so that finding its implementation out in the project would be much easier.

Now in our project, we are pursuing a hacky solution to this problem using extensions. But this usage is not helping us about clearity a lot, such as :

```swift
  	protocol PaymentDelegate
  	{
   		func paymentIsDone(status: Bool)
   	}
   	
   	class PaymentViewController:UIViewController, PaymentDelegate
   	{
   	}

   	// MARK: PaymentDelegate
   	extension PaymentViewController
   	{
   		func paymentIsDone(status: Bool)
   		{
   			// Do something.
   		}
   	}
```
##Intellisense Wise

Protocol function names are generally tended to be forgotten. In order to find out what was the name of the method in the related Protocol, it is necessary to go to that protocol declaration and find out which is the function you seek for.

Instead of going back and finding out the function that way. As a developer i would like to get that information at the context i am currently in. 

What would be cool is, if i provide the ide with protocol name , it would provide me back with the intellisense about the protocol functions it provides.

####Current Implementation: 
```swift
 	func paymentIsDone(status: Bool)
  	{
  		// Do something.
   		// This implementation is plain and doesnt help us understand 
   		// whether it is protocol function implementation or not
  	}
```
###Suggestion 1:
```swift
	 @Implement<PaymentDelegate>
	 func paymentIsDone(status: Bool)
	 {
	 	// Do something.
	 	// After entering annotation it can provide me with intellisense 
	 	// about the functions it covers.
    }
```
###Suggestion 2:
```swift
	implement func<PaymentDelegate> paymentIsDone(status: Bool)
	{
		// Do something.
		// After entering name of the Protocol 
		// it can provide me with intellisense about the functions it covers.
    }
```

This suggestions may provide us better implementation of protocol functions in the programming context.


 
