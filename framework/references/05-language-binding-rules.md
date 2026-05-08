# Part 5 — The 7 Cardinal Rules of Language Binding Code

These rules apply to ANY task involving cross-language boundaries (N-API, FFI, WASM, etc.)

**v2 note:** when any wave crosses a language boundary, the `[TDE-GREEN]` Reviewer role is **escalated from Sonnet to Opus** — field-name drift and ID truncation are reasoning bugs, not typo bugs, and they are the exact class of issue Sonnet is most likely to wave through.

## 1. NEVER shadow foreign state

If the foreign library owns a state variable, never create a local mirror. Always read the authoritative source. If no getter exists, add one. **Shadow variables WILL diverge.**

## 2. NEVER ignore return values from foreign calls

If `foreignLib.doSomething()` returns success/failure, ALWAYS check it before updating local state. **Unconditional state updates after foreign calls are a guaranteed source of bugs.**

## 3. VERIFY field names match across EVERY boundary

When JS sends `{taskType: 1}` and C++ reads `"type"`, the data is silently lost. Compile a field name mapping table for every N-API function. Check:

- JS → C++ (write path)
- C++ → JS (read path)
- `.d.ts` vs actual C++ output

## 4. NEVER truncate ID types

If the foreign library uses 64-bit IDs, the binding layer MUST use 64-bit throughout. `int` truncation is a silent data corruption time bomb.

**Use `Int64Value()` not `Int32Value()` for all IDs.**

## 5. Type declarations (.d.ts) must be generated or verified against C++ output

Never hand-written and trusted. **Hand-written `.d.ts` files WILL drift from actual C++ behavior.** After every C++ change, verify `.d.ts` matches.

## 6. Every field remapping must be applied consistently

If `getTaskStatus()` remaps `idRaw` to `taskId`, then `getTasksByStatus()`, `getTasksByPriority()`, and `getTaskHistory()` MUST also remap.

## 7. Stubs must NEVER return success

A stub that returns `{success: true}` when it does nothing is worse than `{success: false, error: "Not implemented"}`. **False success creates false confidence.**
