// Minimal Swift fixture for perf-suite adapter testing. Hits the
// Swift adapter's xproc-roundtrip and DB-query patterns.

import Foundation

@_silgen_name("rust_export_function")
func rustExportFunction() -> Int32

@objc class Bridge: NSObject {
    @objc func compute() -> Int { 42 }
}
