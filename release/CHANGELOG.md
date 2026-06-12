# SmartTAR STAR v1.2.0

## Release Title

**v1.2.0 - Responsive Analysis Engine, Safer Staging, and STAR Block Optimizations**

---

## Release Notes

SmartTAR STAR v1.2.0 is a stability, performance, and architecture-focused release.

This version significantly improves archive planning, content analysis responsiveness, cross-volume staging behavior, and internal STAR block layout while keeping the original project philosophy intact:

> SmartTAR is not a custom compression engine.  
> It is a smart PowerShell wrapper and STAR container orchestrator built on top of Windows `tar.exe` / `bsdtar`.

The goal of v1.2.0 is to get more practical value from the built-in Windows archiving backend through smarter data grouping, safer staging, better verification, and cleaner internal structure.

---

## Key Features & Architectural Improvements

### 1. CPU-Aware Parallel Content Analysis

Previous versions performed content analysis sequentially.  
On larger datasets, this made the planning phase noticeably slower.

SmartTAR STAR v1.2.0 introduces parallel content analysis using a PowerShell `RunspacePool`.

The parallel analysis covers:

```text
magic byte detection
sample reading
byte entropy calculation
zero-byte ratio calculation
unique byte counting
text / binary / store-like classification
```

To avoid overloading smaller systems, the worker count is automatically limited using a safe CPU-aware scale:

```text
≤ 2 logical threads  → 1 worker
≤ 4 logical threads  → 2 workers
> 4 logical threads  → 4 workers
```

This improves Smart profile planning speed while keeping the system responsive.

---

### 2. Improved Smart Profile Behavior

The `Smart - max compression` profile now uses full content analysis and a clear max-compression strategy.

Current Smart profile block strategy:

```text
structure → XZ9
text      → XZ9
unknown   → XZ9
binary    → XZ9
archives  → STORE
```

Already-compressed or archive-like data is stored without unnecessary recompression, while compressible data is grouped and compressed using XZ9.

---

### 3. Compressed STAR Structure Block

The internal directory structure block is now compressed using XZ9 when available.

Old internal layout:

```text
000001_structure.tar
```

New internal layout:

```text
000001_structure.tar.xz
```

A safe fallback to STORE remains available if XZ9 structure block creation fails.

In validation testing, the structure block was reduced from approximately:

```text
120 KB → 2.5 KB
```

while archive verification remained successful.

---

### 4. Safer Cross-Volume Staging Behavior

SmartTAR continues to prefer hardlink-based staging where possible.

When hardlinks are not available, for example during cross-volume operations, SmartTAR can fall back to copy-based staging instead of immediately fragmenting the archive into many small chunked blocks.

The chunked fallback remains available as a last-resort safeguard.

This improves stability when working across different disks, volumes, or more restrictive filesystem environments.

---

### 5. Cleaner Compression Profiles

The user-facing compression profiles were simplified and clarified.

Current profiles:

```text
Balanced - mixed blocks
Smart - max compression
Solid - single block
Store - no compression
```

Older internal naming such as `Hybrid` and `SmartXZ` has been removed from the user-facing workflow.

---

### 6. Shorter Runtime Status Messages

Long runtime progress messages were simplified.

Example:

```text
Analyzing content...
```

This keeps the GUI cleaner and easier to read during longer operations.

---

### 7. More Compact Stable Report Output

The final report was cleaned up for stable use.

The report now focuses on the most important information:

```text
Compression groups
Compression method summary
Analysis diagnostics
Verification result
```

Verbose development diagnostics were removed from the stable output, including:

```text
entropy summary
unique byte summary
heuristic matrix commentary
compression preference branch listing
```

---

## Validation Summary

SmartTAR STAR v1.2.0 was validated across all main profiles:

```text
Smart - max compression   OK
Balanced - mixed blocks   OK
Solid - single block      OK
Store - no compression    OK
Verify                    OK
```

Example validation result using the Smart profile:

```text
Source size: 415.37 MB
Archive size: 140.79 MB
Ratio: 33.89 %
Saved: 66.11 %
Verification: OK
```

The Smart profile result confirms that the updated block layout and compressed structure block work correctly while preserving archive integrity.

---

## Internal STAR Layout

A typical Smart profile archive now uses an internal block layout similar to:

```text
manifest.json
blocks/
  000001_structure.tar.xz
  000002_text.tar.xz
  000003_unknown.tar.xz
  000004_archives.tar
  000005_binary.tar.xz
```

Each internal block remains a standard tar-compatible unit:

```text
.tar
.tar.xz
.tar.zst
```

The STAR container adds:

```text
manifest metadata
block grouping
block hashing
verification
diagnostics
salvage-friendly structure
```

---

## Design Philosophy

SmartTAR STAR is not intended to replace specialized commercial compression engines.

Instead, SmartTAR focuses on:

```text
smart block planning
content-aware grouping
safe use of Windows tar.exe / bsdtar
clear manifest structure
block-level verification
salvage-friendly archive layout
no external compressor dependencies
```

The result is a practical, dependency-light STAR container format that gets more out of the built-in Windows tar engine through better orchestration.

---

## Summary

SmartTAR STAR v1.2.0 improves performance, stability, and internal archive structure while preserving the original lightweight wrapper design.

Main highlights:

```text
CPU-aware parallel content analysis
safer staging behavior
compressed structure block
cleaner compression profiles
shorter GUI progress messages
simplified stable reports
verified STAR archive integrity
```

This release is considered the stable v1.2 baseline.
