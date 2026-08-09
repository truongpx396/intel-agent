---
description: 'Instructions for client/server state, data fetching, routing, and forms using TanStack Query/Router/Form, Zustand, and React Hook Form + Zod'
applyTo: '**/*.tsx,**/*.jsx,**/*.ts'
---

# State Management & Data Libraries Instructions

Conventions for state, data fetching, routing, and forms in a React 19 application. Use the right
tool for each kind of state, and keep concerns separated. Complements
[reactjs.instructions.md](./reactjs.instructions.md) — the React performance and component rules
there apply on top of everything below.

These rules assume the TanStack + Zustand stack named below. Where the project has already
standardized on an equivalent (Redux Toolkit + RTK Query, SWR, Formik, React Router), apply the same
separation-of-concerns principles to those libraries instead of introducing a second one.

## Choosing the Right State Tool

Match the tool to the kind of state; do not mix responsibilities:

| Kind of state | Use | Avoid |
|---------------|-----|-------|
| Server/async data (fetch, cache, sync) | **TanStack Query** | Storing fetched data in Zustand or `useEffect` |
| Global client/UI state (theme, sidebar, session flags) | **Zustand** | Putting server data or form state here |
| Local component state | `useState`/`useReducer` | Reaching for a global store |
| URL/navigation state | **TanStack Router** | Duplicating route state in a store |
| Form state & validation | **TanStack Form** or **React Hook Form + Zod** | Controlled `useState` per field for complex forms |
| Derived state | Compute during render | Syncing with `useEffect` |

Rule of thumb: **server state ≠ client state.** TanStack Query owns anything that comes from the
backend; Zustand owns ephemeral client-only state. Keeping them separate avoids cache duplication and
stale data.

## TanStack Query (Server State)

- Treat Query as the single source of truth for server data; don't copy query results into Zustand or local state
- Use stable, structured query keys (arrays): `['workspace', workspaceId, 'documents']`; centralize key factories to avoid drift
- Set sensible `staleTime`/`gcTime` per resource; don't refetch constantly for data that rarely changes
- Use `useMutation` for writes; invalidate or `setQueryData` on success to keep the cache fresh
- Prefer optimistic updates for snappy UX, with rollback in `onError`
- Pass `signal` from Query to `fetch` so cancellations propagate
- Handle `isPending`/`isError`/`data` explicitly; render error and empty states, not just the happy path
- Parallelize independent queries (`useQueries` or multiple hooks); avoid dependent-query waterfalls unless truly dependent (use `enabled`)
- Set a typed default `queryFn`/error type on the `QueryClient`; surface errors to an error boundary
- For infinite/paginated data, use `useInfiniteQuery` rather than manual page state
- Validate API responses at the boundary (e.g., Zod) before trusting their shape

## Zustand (Client State)

- Keep stores small and domain-focused; create multiple stores rather than one god store
- **Never store server data in Zustand** — that's TanStack Query's job
- Select narrow slices to minimize re-renders: `useStore(s => s.value)`, not the whole store object
- Use `useShallow` when selecting multiple fields/objects to avoid needless re-renders
- Keep actions inside the store (colocate state + the functions that mutate it)
- Use middleware deliberately: `persist` (validate/migrate hydrated shape), `devtools` in development only
- Don't put derived values in the store; compute them in selectors or during render
- Keep stores serializable-friendly; avoid storing class instances, DOM nodes, or non-plain objects
- For transient values that shouldn't re-render, prefer `useRef` over store state

## TanStack Router (Navigation State)

- Define routes with the type-safe route tree; lean on inferred params and search params
- Treat the URL as the source of truth for shareable/navigational state (filters, tabs, pagination)
- Validate and type `search` params with a schema (`validateSearch` + Zod); don't read raw strings
- Use route `loader`s to start data fetching early and integrate with TanStack Query (preload + cache)
- Code-split routes (lazy route components) to keep the initial bundle small
- Use typed `Link`/`navigate`; avoid hand-built URL strings that bypass type checking
- Handle pending/error UI with router-level boundaries

## Forms

Use **TanStack Form** or **React Hook Form**, with **Zod** for schema validation. Pick one approach
per form area and stay consistent.

- Define a single Zod schema as the source of truth; derive the form's TypeScript type with `z.infer`
- Validate with the schema via the appropriate resolver/adapter (`zodResolver` for RHF; validators for TanStack Form)
- Prefer uncontrolled inputs / register patterns over per-field `useState` for performance
- Keep validation logic in the schema, not scattered across handlers
- Surface field-level errors accessibly (associate messages with inputs, set `aria-invalid`)
- Re-validate server-side too; client validation is UX only and must not be trusted (see Security)
- For async submits, integrate with `useMutation` (TanStack Query) and reflect pending/error state in the UI
- Reset/sync form state intentionally on success; avoid effect-based prop→state syncing

## Integration Patterns

- **Router loader → Query:** prefetch in the loader, read with `useQuery` in the component for cache reuse
- **Form → Mutation:** submit handler calls `useMutation`; invalidate affected queries in `onSuccess`
- **Query → UI state:** derive UI state from query status; keep only genuinely client-only flags in Zustand
- Keep a single `QueryClient` at the app root; configure global defaults (retry, staleTime, error handling) there

## Security

- Validate all external/server data and form input with Zod at the boundary; treat API and LLM output as untrusted
- Validate the shape of any `persist`ed Zustand state and `localStorage` reads before use
- Never store tokens or secrets in Zustand `persist`/`localStorage`; use httpOnly cookies set by the server
- Always enforce validation and authorization server-side, regardless of client checks
- For full secure-coding requirements, follow `.github/instructions/security-and-owasp.instructions.md`, which takes precedence on security matters

## Common Pitfalls to Avoid

- Caching server data in Zustand instead of TanStack Query (dual source of truth, stale data)
- Selecting the whole Zustand store (or unstable selectors) and over-rendering
- Unstable or inconsistent query keys causing cache misses and refetch storms
- Dependent-query waterfalls where parallel fetching was possible
- Per-field `useState` for large forms instead of RHF/TanStack Form
- Duplicating URL/navigation state in a store instead of reading it from the router
- Trusting client-side validation without server-side enforcement
- Persisting tokens/PII via `persist`/`localStorage`
