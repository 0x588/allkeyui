# Vendored wallet core

This directory contains the project-local Go packages used by the macOS native
bridge. The `base`, `electrum`, and `hdwallet` packages were migrated from the
original `crab/wasm` implementation and now belong to the parent `NativeCore`
module. The build does not depend on a sibling checkout.

WASM entry points, generated `.wasm` files, and npm packages are intentionally
excluded because the macOS app compiles these packages directly as native code.
The original module manifests are retained as `go.mod.source` and
`go.sum.source` for provenance; the active manifests live in `NativeCore`.
