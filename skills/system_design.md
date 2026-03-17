# System Design Principles and Patterns

## Architecture Patterns

### Layered Architecture
- **Presentation Layer**: UI, API endpoints
- **Business Logic Layer**: Domain logic, use cases
- **Data Access Layer**: Database, external services
- **Benefits**: Separation of concerns, testability

### Microservices
- Independent deployable services
- Service boundaries by business capability
- Inter-service communication (REST, gRPC, message queues)
- **Benefits**: Scalability, team autonomy, tech diversity

### Event-Driven Architecture
- Producers emit events
- Consumers subscribe and react
- Message broker (Kafka, RabbitMQ, Redis)
- **Benefits**: Loose coupling, scalability, audit trail

### Clean Architecture / Hexagonal
- Domain at center (entities, use cases)
- Ports and adapters pattern
- Dependencies point inward
- **Benefits**: Testability, framework independence

## Design Principles

### SOLID Principles
- **S**ingle Responsibility: One reason to change
- **O**pen/Closed: Open for extension, closed for modification
- **L**iskov Substitution: Subtypes must be substitutable
- **I**nterface Segregation: Many specific interfaces better than one general
- **D**ependency Inversion: Depend on abstractions

### Other Key Principles
- **DRY**: Don't Repeat Yourself
- **KISS**: Keep It Simple, Stupid
- **YAGNI**: You Aren't Gonna Need It
- **Composition over Inheritance**

## Scalability Patterns

### Horizontal Scaling
- Load balancing
- Stateless services
- Database sharding/replication

### Caching Strategies
- Application caching (Redis, Memcached)
- CDN for static assets
- Database query caching

### Database Patterns
- CQRS (Command Query Responsibility Segregation)
- Event Sourcing
- Read replicas for scaling reads

## API Design

### RESTful APIs
- Resource-based URLs
- HTTP methods (GET, POST, PUT, DELETE)
- Status codes appropriately
- Versioning strategy

### GraphQL
- Single endpoint
- Client-specified queries
- Schema as contract
- Type safety

### gRPC
- High performance
- Protocol Buffers
- Streaming support
- Service definitions

## Security Considerations

- Authentication (OAuth2, JWT)
- Authorization (RBAC, ABAC)
- Input validation
- Rate limiting
- HTTPS everywhere
- Secrets management

## Design Process

1. **Requirements Gathering**: Functional and non-functional
2. **Capacity Planning**: Expected load, growth
3. **Component Identification**: Major system parts
4. **Interface Design**: APIs and contracts
5. **Data Modeling**: Entities and relationships
6. **Technology Selection**: Right tools for the job
7. **Trade-off Analysis**: Document decisions and why
8. **Iteration**: Refine based on feedback

## Documentation

Always document:
- System overview and goals
- Component diagrams
- API specifications
- Data flow diagrams
- Deployment architecture
- Decision records (ADRs)
