---
name: linkedin-research
description: Look up LinkedIn people and CSR decision-makers through the team's n8n LinkedIn server. Use when the user gives a LinkedIn profile URL and wants the person's jobs or education, or asks who handles CSR, sustainability, ESG, foundation or HR at a company.
---

# LinkedIn research

Two tools on the `linkedin` MCP server. Both run n8n workflows that cache, rate-limit and save every result to Postgres.

| Tool | Input | Returns |
|---|---|---|
| `scrape_profile` | `url` (`https://www.linkedin.com/in/<id>/`), `force` (default false) | `{source, scraped_at, profile}`: name, headline, every job and degree |
| `find_csr_leads` | `company` (name as on LinkedIn), `cin` (optional Indian CIN) | `{company, saved, leads, errors}`: leads scored 5-10 with a `match_reason` |

## Rules

- **One call at a time.** Never call these tools in parallel or in a tight loop. Each uncached profile takes 1-5 minutes on purpose (human-like pacing protects the LinkedIn accounts).
- **Use the cache.** `source: "cache"` is normal: profiles under 90 days old are not scraped again. Set `force: true` only when the user explicitly asks for a fresh scrape.
- **Daily caps are hard limits.** A response with `daily cap reached` (HTTP 429) means stop and tell the user. Do not retry until tomorrow.
- **Scrape errors** (HTTP 502) usually mean the account is logged out or LinkedIn changed its page. Report the error text; do not retry more than once.
- **Bulk work** (more than about 10 profiles) belongs in n8n, not in a chat. Suggest that instead of looping.
- **Personal data.** Results are personal data under the DPDP Act. Use only what the task needs and do not paste whole profiles into other systems.

## Setup check

If the `linkedin` tools are missing or every call fails with 401, the user has not set up the plugin's environment. Point them to "Connect Claude Code" in the repository README.
