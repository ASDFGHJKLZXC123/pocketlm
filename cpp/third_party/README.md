# third_party

## llama.cpp

Pinned tag: **b8833** (commit `45cac7ca703fb9085eae62b9121fca01d20177f6`)

The project pins tag `b8833` by name. That exact tag exists on the upstream
repository and was verified with `git ls-remote --tags` before pinning. No
fallback was required.

To update the submodule intentionally (its own PR, full quality + repro +
memory tests re-run):

```
git -C cpp/third_party/llama.cpp fetch --tags
git -C cpp/third_party/llama.cpp checkout <new-tag>
git add cpp/third_party/llama.cpp
git commit -m "chore: bump llama.cpp to <new-tag>"
```

Never point this submodule at a branch or HEAD. Reproducible builds require an
exact pinned revision.
