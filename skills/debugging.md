# Systematic Debugging Methodology

## The Debugging Process

### Phase 1: Problem Reproduction
- [ ] Reproduce the bug consistently
- [ ] Document exact steps to reproduce
- [ ] Note environment details (OS, versions, config)
- [ ] Identify scope (single user? all users? specific conditions?)
- [ ] Check if it's a regression (git log, recent changes)

### Phase 2: Information Gathering
- [ ] Collect all error messages and stack traces
- [ ] Check application logs
- [ ] Review system logs (syslog, journald)
- [ ] Examine recent code changes
- [ ] Check configuration changes
- [ ] Verify environment differences

### Phase 3: Hypothesis Formation
Generate potential causes:
- Recent code changes
- Configuration issues
- Data-related problems
- Environment differences
- Dependency updates
- Race conditions
- Resource exhaustion

### Phase 4: Testing Hypotheses
- Test ONE hypothesis at a time
- Make minimal changes
- Document results
- Use binary search (bisection) to narrow down
- Add logging/instrumentation as needed

### Phase 5: Fix and Verify
- Implement minimal, focused fix
- Test the fix thoroughly
- Check for regressions
- Run full test suite
- Verify in staging/production

### Phase 6: Post-Mortem
- Document the root cause
- Document the fix
- Identify preventive measures
- Update tests/checks to catch similar issues

## Common Debugging Tools

### Code Analysis
```bash
# Find recent changes
git log --oneline -20
git diff HEAD~5 HEAD

# Search code
grep -r "pattern" src/
find . -name "*.js" -exec grep -l "pattern" {} \;
```

### Log Analysis
```bash
# Tail logs with filtering
tail -f app.log | grep ERROR
journalctl -u myapp -f
```

### Process Debugging
```bash
# Check running processes
ps aux | grep myapp
lsof -p <pid>

# Resource usage
top -p <pid>
strace -p <pid>
```

## Common Bug Categories

### Syntax/Compile Errors
- Read error messages carefully
- Check line numbers (may be offset)
- Look for missing brackets, semicolons
- Check for typos

### Runtime Errors
- Null/undefined dereferences
- Type mismatches
- Index out of bounds
- Stack overflow

### Logic Errors
- Off-by-one errors
- Incorrect boolean logic
- Wrong operator precedence
- State management issues

### Concurrency Issues
- Race conditions
- Deadlocks
- Starvation
- Atomicity violations

### Performance Issues
- Infinite loops
- Memory leaks
- N+1 queries
- Blocking operations

## Debugging Techniques

### Rubber Duck Debugging
Explain the code/problem to someone (or something) step by step

### Binary Search Debugging
Comment out half the code, test, narrow down

### Print Debugging
Add strategic logging to trace execution flow

### Backwards Analysis
Start from error and trace backwards through code flow

### Checklist Method
Systematically verify each assumption

## Anti-Patterns to Avoid

❌ **Don't:**
- Change multiple things at once
- Skip reproduction step
- Ignore error messages
- Assume without verifying
- Fix symptoms, not causes
- Skip testing after fix

✅ **Do:**
- Stay systematic
- Document everything
- Test one change at a time
- Verify assumptions
- Understand root cause
- Add regression tests

## Debugging Mindset

1. **Stay Calm**: Bugs are puzzles to solve
2. **Be Systematic**: Follow the process
3. **Stay Curious**: Ask "why" repeatedly
4. **Be Humble**: Your assumptions may be wrong
5. **Be Persistent**: Keep going until you understand
6. **Learn**: Each bug teaches you something
