# Coding Style Rules

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

## Code Structure
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
