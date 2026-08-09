---
description: 'Instructions for writing React 19 + TypeScript code following idiomatic patterns and Vercel React performance best practices'
applyTo: '**/*.tsx,**/*.jsx,**/*.ts,**/*.js'
---

# React Development Instructions

Write idiomatic, performant React 19 + TypeScript. These instructions follow the
official [React docs](https://react.dev/) and the
[Vercel React Best Practices](https://vercel.com/blog/introducing-react-best-practices)
([rules source](https://github.com/vercel-labs/agent-skills/tree/main/skills/react-best-practices/rules)).

> **Related:** For server/client state, data fetching, routing, and forms (TanStack Query/Router/Form,
> Zustand, React Hook Form + Zod), see
> [state-management.instructions.md](./state-management.instructions.md).

> **Note on scope:** the client-side, bundle, re-render, rendering, and JavaScript rules apply to any
> React app. Section 3 (Server-Side Performance) and the Server Components / Server Actions rules
> apply only to SSR/RSC frameworks such as Next.js or Remix — skip them in a client-only SPA (Vite,
> CRA) and revisit if SSR is introduced later.

## Core Principle: Optimize by Impact, Not by Instinct

Performance work compounds and must be ordered by impact. Fix high-impact problems first; do not
micro-optimize loops while a request waterfall costs 600ms or a 300KB bundle ships on every page.
Priority order (CRITICAL → LOW):

1. **Eliminate async waterfalls** (CRITICAL)
2. **Reduce bundle size** (CRITICAL)
3. **Server-side performance** (if SSR is used)
4. **Client-side data fetching**
5. **Re-render optimization**
6. **Rendering performance**
7. **Advanced patterns**
8. **JavaScript performance** (incremental)

## General Instructions

- Write function components only; no class components
- Keep components small, focused, and composable
- Use TypeScript everywhere; type props, state, and hook returns explicitly
- Favor clarity over cleverness; colocate related logic
- Keep the happy path flat; return early from handlers and render guards
- Write comments in English by default; avoid emoji in code and comments
- Target React 19 features (Actions, `use`, `useOptimistic`, ref-as-prop, improved Suspense)

## 1. Eliminate Async Waterfalls (CRITICAL)

- Start independent async work in parallel; never `await` sequentially when there's no dependency:
  ```tsx
  // Bad — sequential
  const user = await fetchUser(id);
  const posts = await fetchPosts(id);
  // Good — parallel
  const [user, posts] = await Promise.all([fetchUser(id), fetchPosts(id)]);
  ```
- Check cheap conditions / early-exit branches **before** awaiting, so unused branches don't block on data they never use
- Defer an `await` until the value is actually needed rather than awaiting eagerly at the top
- Avoid cascading `useEffect` chains where one effect's result triggers the next fetch; fetch in parallel or restructure
- Use Suspense boundaries to parallelize loading rather than gating the whole tree on one slow request

## 2. Reduce Bundle Size (CRITICAL)

- Code-split heavy or rarely-used components with `React.lazy` + `Suspense` / dynamic `import()`
- Avoid barrel-file (`index.ts` re-export) imports that pull in entire libraries; import specific paths
- Defer non-critical third-party scripts; don't block first render on analytics/widgets
- Preload critical resources that you know are needed soon; lazy-load the rest
- Keep import paths analyzable (static, literal) so the bundler can tree-shake
- Audit bundle size when adding dependencies; prefer lighter alternatives and native APIs

## 3. Server-Side Performance (SSR / React Server Components only)

- Parallelize data fetching across and within components; avoid nested sequential fetches
- Deduplicate identical requests (e.g., React `cache`) instead of refetching per component
- Hoist static I/O out of request paths; avoid shared mutable module state across requests
- Authenticate and authorize inside Server Actions; never trust the client
- Keep props serializable; pass only the fields the client needs

## 4. Client-Side Data Fetching

> Use **TanStack Query** for server state — see [state-management.instructions.md](./state-management.instructions.md)
> for query keys, caching, mutations, and integration patterns.

- Use a caching/dedup layer (e.g., SWR or TanStack Query) instead of ad-hoc `fetch` in effects
- Deduplicate in-flight requests for the same key
- Validate `localStorage`/`sessionStorage` reads against a schema; never trust persisted shape
- Add and clean up event listeners in `useEffect`; mark scroll/touch listeners `{ passive: true }` where possible
- Always provide an AbortController/cleanup for fetches started in effects to avoid setting state after unmount
- Pass timeouts to network calls; handle loading, error, and empty states explicitly

## 5. Re-render Optimization

- **Derive, don't sync:** compute derived state during render instead of mirroring props into state via `useEffect`
- Use functional `setState` (`setCount(c => c + 1)`) when the next state depends on the previous
- Use lazy state init for expensive computations: `useState(() => parse(localStorage...))`, not `useState(parse(...))`
- Memoize stable callbacks/values passed to memoized children with `useCallback`/`useMemo`; wrap pure leaf components in `React.memo`
- Don't `useMemo` trivial expressions — the overhead can exceed the work
- Split large combined hooks/state so unrelated updates don't re-render everything
- Never define components inside other components (new identity every render → remounts); hoist them out
- Use `useRef` for transient values that shouldn't trigger re-renders (timers, last-seen values)
- Use `useTransition` / `useDeferredValue` to keep heavy updates from blocking input
- Move work that belongs in an event out of effects ("move effect to event")
- Note: React 19's compiler reduces manual memoization needs; still apply these where measurable

## 6. Rendering Performance

- Render conditionally instead of mounting hidden subtrees; use `<Activity>` (React 19) for keep-alive/offscreen content
- Hoist static JSX out of render so it isn't recreated each pass
- Avoid hydration flicker; suppress hydration warnings only for genuinely client-variable content (dates, random)
- Use `content-visibility` / resource hints for large or below-the-fold content
- Always provide stable, unique `key`s for lists; never use array index when items reorder
- Keep SVG precision reasonable and animate a wrapper rather than many nodes

## 7. Advanced Patterns

- Use a `useLatest`/ref pattern to read the freshest value inside stable callbacks without re-subscribing
- Keep `useEffect`/`useEffectEvent` dependency arrays correct; extract non-reactive logic with `useEffectEvent`
- Initialize one-time singletons outside the component or guard with a ref
- Prefer `useLayoutEffect` only for synchronous DOM measurement; default to `useEffect`

## 8. JavaScript Performance (incremental)

- Combine multiple passes over the same collection into a single loop
- Use `Set`/`Map` for membership and lookups instead of repeated `Array.includes`/`find`
- Build index maps once instead of repeated linear scans
- Cache property access and function results in hot loops; hoist regex literals out of functions
- Prefer immutable helpers like `toSorted`/`toSpliced` over mutate-then-copy
- Use `flatMap` + filter fusion, early exits, and length checks before expensive work
- Batch DOM/CSS reads and writes to avoid layout thrashing; defer non-urgent work with `requestIdleCallback`

## Component and Hooks Rules

- Call hooks only at the top level, never conditionally or in loops
- Name custom hooks `useX`; keep them focused and composable
- Keep `useEffect` dependency arrays complete and correct; don't disable the lint rule to "fix" loops
- Clean up every subscription, timer, and listener returned from an effect
- Lift state only as high as needed; prefer composition (`children`) over prop drilling; use Context sparingly for low-frequency global state
- In React 19, pass `ref` as a normal prop; `forwardRef` is no longer required

## TypeScript

- Type component props with explicit `type`/`interface`; avoid `React.FC` (prefer explicit props + return)
- Avoid `any`; use `unknown` at boundaries and narrow
- Type event handlers with React's event types (`React.ChangeEvent<HTMLInputElement>`, etc.)
- Use discriminated unions for component variants and reducer actions
- Derive prop types from schemas (e.g., zod `z.infer`) where data crosses boundaries

## Accessibility

- Use semantic HTML; reserve ARIA for gaps semantics can't cover
- Ensure keyboard operability and visible focus states for all interactive elements
- Provide accessible names (labels, `aria-label`) and `alt` text for images
- Maintain sufficient color contrast and respect `prefers-reduced-motion`

## Testing

- Use React Testing Library; test behavior and accessibility, not implementation details
- Query by role/label/text over test IDs
- Cover loading, error, and empty states for data-driven components
- Use `userEvent` for interactions; await async UI with `findBy*`/`waitFor`

## Security

- Never render unsanitized HTML; avoid `dangerouslySetInnerHTML`, and sanitize with DOMPurify if unavoidable
- Treat all props/URL params/storage and LLM output as untrusted input
- Validate redirect targets (relative, same-origin only) to prevent open redirects
- Validate `postMessage` origins before trusting message data
- Don't store tokens/secrets in `localStorage`; use httpOnly cookies set by the server
- For full secure-coding requirements, follow `.github/instructions/security-and-owasp.instructions.md`, which takes precedence on security matters

## Tooling and Workflow

- Format/lint with Prettier + ESLint (`eslint-plugin-react-hooks`, `react-refresh`); fix hook-deps warnings, don't suppress them
- Type-check with `tsc --noEmit` in CI; treat type errors as failures
- Run lint, type checks, and tests before committing

## Common Pitfalls to Avoid

- Sequential `await`s for independent work (waterfalls)
- Barrel imports that defeat tree-shaking
- Syncing props into state with `useEffect` instead of deriving
- Defining components inside render (causes remounts)
- Missing/incorrect effect cleanup and dependency arrays
- Array index as `key` for reorderable lists
- Recomputing expensive values every render instead of lazy init/memoization
- `dangerouslySetInnerHTML` with unsanitized content
- Storing tokens/PII in `localStorage`
- Over-memoizing trivial expressions
