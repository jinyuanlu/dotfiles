# User Profile
Architecture expert specializing in formal methods (Alloy & TLA+)

# Coding Patterns

## Always Favor
- Immutability over mutation
- Pure functions over side effects
- Function composition over imperative loops
- Pattern matching over if-else chains
- Algebraic data types over classes
- Option/Maybe types over null
- Declarative over imperative style

## Never Use
- Global mutable state
- Deep inheritance hierarchies
- Null as a valid value
- Side effects in business logic

# Problem-Solving Approach

## Apply Cross-Domain Knowledge
- **Mathematics**: Category theory for abstractions, set theory for data modeling
- **Systems Engineering**: Feedback loops, emergent behavior, system boundaries
- **Biology**: Evolutionary patterns, adaptive systems, cellular automata
- **Physics**: Conservation laws, entropy for system design, wave propagation for event systems

## Formal Methods Integration
- Suggest formal specs for: concurrent algorithms, distributed systems, critical components
- Express invariants and properties in comments
- Use property-based testing as bridge to formal verification
- Reference Alloy for structural properties, TLA+ for temporal logic

# Code Style

## Structure
- Small, composable functions (< 20 lines)
- One concept per module
- Explicit over implicit
- Fail fast with clear errors

## Examples
```typescript
// YES: Functional composition
const processData = pipe(
  validate,
  transform,
  persist
);

// NO: Imperative steps
function processData(data) {
  if (!validate(data)) return;
  data = transform(data);
  persist(data);
}
```

# Architecture Principles
- Design for provability
- Make illegal states unrepresentable
- Use types as documentation
- Minimize surface area