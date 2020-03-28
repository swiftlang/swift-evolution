# Service Manager Extension

* Proposal: [Swiftpm Service Manager Extension](swiftpm-service-manager-extension.md)
* Authors: [Amr Aboelela](https://github.com/amraboelela)
* Review Manager:
* Status:
* Implementation: 

## Introduction

This proposal suggests to create swift service manager extension of swiftpm, in which developers can publish services which depend of each other. Each service has a protocol and an implementation. the consumers of thoses services can import them into their project target as is, or they can replace one or more service implementations down the line. Swift Foundation framework should provide a ServiceProducer class to provide the current implementation of any required service in the runtime. This can be decided during the build process.

## Motivation

This will increase the usuability of developers modules, after splitting them into services, when we split libraries into smaller building blocks which can be used as is without modifications, or we can replace any service (module) as needed, even if the service is down the heirarchy levels.

The current swiftpm imbed (copies) packages under our own project, which makes it difficult to make changes to those libraries. The suggested solution will encourage developers to split their liraries into smalled building blocks called services with 2 parts (interface, and implementation), they would provide their default implementation for each service, while the consumer project can choose to use the default implementation or create his/her own implementation, and publish it for other developers to use.

This would make open source projects more productive and colarable. Also for private company projects can make their projects more scalable and productive.

## Proposed solution

Create an extension of swiftpm, to handle services, including the defintion of modules as service, their dependencies of each other, how to overide the implementation of existing service down the line of dependencies, etc.


## Detailed design

Similar to Package.swift configuration file, we will have Service.swift configuration file for each service. While in the Package.swift, we will add the serviceDependencies to the current package.

Let's say developer Ahmed published a service called Service1, which depends on Service2. He would define that in his Service.swift file as:

```
Service(name: "Service1", dependencies: ["http://github.com/anotherguy/services/AnotherService", "services/Service2"], ...)
```


I, Amr, would like to consume Service1, while writing my own implementation of Service2, called AmrService2. Then I can define it in my Package.swift file as:

```
Package(..., serviceDependencies: ["http://github.com/ahmed/services/Service1", "services/AmrService2"], ...)
```

Now Eric, like also to use Ahmed Service1, while also overriding his Service2 with mine (AmrService2), then he can define that in his Package.swift file as:

```
Package(..., serviceDependencies = ["http://github.com/ahmed/services/Service1", "http://github.com/amr/services/AmrService2"], ...)
```

In this case, the order matter, because the swift builder should know to override Service2Implementation (which is the dependent of Service1), with AmrService2, as it came later in the list of dependent services.

There is only one service implementation class allowed for each service protocol in each project target, if the builder find more than one implemented in the same project going to the same target, it should give an error. Also the Foundation ServiceProducer (suggested built-in class), should be able to provide me with a singleton instance of a service implementation that I request, given the service protocol name in run time. For example to get Service2 implementation:

```
let service2 = ServiceProducer.service(with: Service2) // Service2 is the protocol name
```

In case of Ahmed project, it should return a singleton instance of Service2Implementation, which is his default implementation class; in case of Amr project mentioned above, it should return AmrService2.

## Alternatives considered

No alternatives were considered for now.

