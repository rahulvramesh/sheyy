# Chain-of-Thought Prompting Guide

## What is Chain-of-Thought (CoT)?

Chain-of-Thought prompting is a technique where you explicitly show your reasoning process step-by-step before giving a final answer. This leads to:
- Better problem-solving on complex tasks
- More accurate results
- Easier to debug reasoning
- Better transparency

## When to Use CoT

Use CoT for:
- Multi-step problems
- Complex reasoning tasks
- Mathematical calculations
- Logical deduction
- Planning and design
- Debugging and troubleshooting

## CoT Structure

### Basic Template
```
<problem statement>

Let me think through this step by step:

Step 1: [Initial analysis]
Step 2: [Breaking down components]
Step 3: [Considering options]
Step 4: [Evaluating trade-offs]
Step 5: [Conclusion]

Therefore, the answer is: [final answer]
```

### Advanced: Self-Consistency
Generate multiple CoT reasoning paths and take the most common conclusion.

## CoT Patterns

### 1. Sequential Reasoning
Break down linear processes:
```
To design this API:
1. First, I'll identify the core entities
2. Then, define the relationships between them
3. Next, design the endpoints needed
4. Finally, specify request/response formats
```

### 2. Comparative Analysis
Compare options systematically:
```
Option A vs Option B:
- Scalability: A is better because...
- Complexity: B is simpler because...
- Maintenance: A requires more effort because...
- Recommendation: Choose B for MVP, migrate to A later
```

### 3. If-Then Reasoning
Handle conditional logic:
```
If the error occurs on startup:
  Then check configuration
  Else if it occurs during runtime:
    Then check resource limits
  Else:
    Then check recent code changes
```

### 4. First Principles Thinking
Break down to fundamentals:
```
What are we really trying to do?
- Core need: [identify fundamental requirement]
- Constraints: [list true constraints]
- Assumptions: [question each assumption]
- Solution: [build from fundamentals]
```

## Example: Code Review with CoT

```
Reviewing this function:

Step 1 - Understanding:
- This function handles user authentication
- It takes username and password
- Returns JWT token on success

Step 2 - Security Analysis:
- Password is being logged (CRITICAL ISSUE)
- No rate limiting visible
- Token expiration not checked

Step 3 - Performance:
- Database query could be optimized
- No caching of user data

Step 4 - Recommendations:
1. Remove password from logs immediately
2. Add rate limiting middleware
3. Add token expiration validation
4. Consider Redis for session caching

Priority: Fix #1 immediately, implement others in next sprint.
```

## CoT for Different Tasks

### Debugging
```
The error says "NullPointerException at line 42"

Step 1: What object is null?
- Looking at line 42, it's the `user` variable

Step 2: Where is user assigned?
- It's returned from `getUserById(id)`

Step 3: Can getUserById return null?
- Yes, if user doesn't exist in database

Step 4: Is there a null check?
- No, we immediately call `user.getName()`

Fix: Add null check before using user object
```

### Architecture Design
```
Designing a notification system:

Step 1: Requirements
- Support email, SMS, push notifications
- Must be reliable (don't lose notifications)
- Should scale to 10K notifications/minute

Step 2: Component Design
- API Gateway: receives requests
- Message Queue: buffers notifications (Kafka)
- Workers: process different notification types
- Providers: third-party services

Step 3: Data Flow
1. Client sends notification request
2. API validates and publishes to Kafka
3. Workers consume and send to providers
4. Dead letter queue for failures
5. Retry mechanism for transient failures

Step 4: Trade-offs
- Kafka adds complexity but ensures durability
- Separate workers allow independent scaling
- DLQ enables manual inspection of failures

Step 5: Implementation Plan
1. Set up Kafka infrastructure
2. Implement API endpoint
3. Create email worker
4. Add monitoring and alerting
```

## Tips for Effective CoT

1. **Number Your Steps**: Makes reasoning easy to follow
2. **Show Your Work**: Don't skip "obvious" steps
3. **Label Decisions**: Explicitly state why you chose X over Y
4. **Check Assumptions**: Question what you're assuming
5. **Summarize**: End with clear conclusions
6. **Be Concise**: Don't ramble, keep focused

## Common Mistakes

❌ **Vague Steps**
"Step 1: Think about it"

✅ **Specific Steps**
"Step 1: Identify the three main user roles and their permissions"

❌ **Jumping to Conclusions**
"The answer is 42"

✅ **Showing Reasoning**
"Step 1: Calculate total = 10+20+12 = 42. Therefore, the answer is 42"

## Practice Prompts

Try using CoT for:
1. Explaining a complex algorithm
2. Designing a database schema
3. Debugging an error
4. Comparing two technologies
5. Planning a project timeline

Remember: The goal is clarity and accuracy, not length. Be thorough but concise.
