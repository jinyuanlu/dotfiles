<!-- AUTO-GENERATED from claude-md-persist.md.tmpl — do not edit directly -->
<!-- Regenerate: bun run gen:skill-docs -->
Find-and-replace (or append) the section. Block format depends on mode:

### Path 4 (Remote MCP)

```markdown
## GBrain Configuration (configured by /setup-gbrain)
- Mode: remote-http
- MCP URL: {MCP_URL}
- Server version: gbrain v{SERVER_VERSION}  (from Step 4c verify)
- Setup date: {today}
- MCP registered: yes (user scope)
- Token: stored in ~/.claude.json (do not commit; never written to CLAUDE.md)
- Artifacts repo: {gstack_artifacts_remote URL or "none"}
- Artifacts sync: {off|artifacts-only|full}
- Current repo policy: {read-write|read-only|deny|unset}
```

The bearer token is **never** written to CLAUDE.md (CLAUDE.md is checked
in to git in many projects). It lives only in `~/.claude.json` where
`claude mcp add` placed it.

### Paths 1, 2a, 2b, 3 (Local stdio)

```markdown
## GBrain Configuration (configured by /setup-gbrain)
- Mode: local-stdio
- Engine: {pglite|postgres}
- Config file: ~/.gbrain/config.json (mode 0600)
- Setup date: {today}
- MCP registered: {yes/no}
- Artifacts sync: {off|artifacts-only|full}
- Current repo policy: {read-write|read-only|deny|unset}
```

Do not write a `## GBrain Search Guidance` block here. `/sync-gbrain` is its
only writer: it writes the block after its read check confirms this repo's
code index answers, and replaces any older block under the same heading.
Step 10 offers to run `/sync-gbrain`.
