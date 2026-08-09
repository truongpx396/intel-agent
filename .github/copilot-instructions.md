<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan:
`specs/001-contextengine-mvp/plan.md`

Active feature: **001-contextengine-mvp** — AISAT-INTEL MVP (Phase 1), an
AI-powered shared second brain. Stack: Go 1.23 (BFF/gateway/kernel) · Python
3.12 (LangGraph RAG agent, ingestion, MCP server) · TypeScript/React 19 (Vite
SPA). Infra: PostgreSQL (RLS), Redis (credits/checkpoints/cache), Qdrant
(hybrid vectors), NATS (async bus), S3 (uploads); Langfuse + OpenTelemetry for
observability. Design artifacts: plan.md, research.md, data-model.md,
quickstart.md, and contracts/ in `specs/001-contextengine-mvp/`.
<!-- SPECKIT END -->
