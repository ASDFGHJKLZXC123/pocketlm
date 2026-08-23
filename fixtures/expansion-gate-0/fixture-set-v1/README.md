# Expansion Gate 0B golden fixtures

This directory is the executable contract pack for the frozen expansion
foundation. It defines data and outcomes only. It does **not** activate catalog
v2, installation record v2, the model-manager API, or the C ABI 2.2 inspector in
production.

`index.json` is the closed inventory. Every other file is listed there with the
SHA-256 of its exact bytes, and every required coverage tag is exercised by at
least one case in the matching family file. Case IDs and coverage tags are
stable API values: append new cases instead of renaming accepted ones.

Each case file uses this shape:

```json
{
  "fixtureSet": "expansion-gate-0/fixture-set-v1",
  "family": "catalog",
  "cases": [
    {
      "id": "catalog/example",
      "accepted": true,
      "coverage": ["example"],
      "input": {},
      "expected": {}
    }
  ]
}
```

Files under `bytes/` are persisted UTF-8 payloads. Their digests cover the
bytes as stored, including the terminal line feed. Consumers must read them as
bytes and must not parse and reserialize them before hashing.

The recipes in the paths, leases, GGUF, publication, and recovery families are
platform-neutral. Later TypeScript, Ruby, C++, iOS, and Android implementations
must consume the same cases while preserving the existing inference event
grammar.
