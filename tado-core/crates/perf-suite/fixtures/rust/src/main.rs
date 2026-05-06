// Minimal Rust fixture used by perf-suite adapter integration tests.
// Touches every per-metric pattern the adapter scans for:
//   - DB query (rusqlite-style execute)
//   - FFI boundary (extern "C")
//   - Allocation that could be pre-sized (Vec::new + push loop)
//   - Hot loop with .clone()
fn main() {
    println!("ready");
}

extern "C" fn ffi_export() -> i32 { 42 }

fn build_vec(n: usize) -> Vec<i32> {
    let v: Vec<i32> = Vec::new();
    let mut v = v;
    for i in 0..n {
        v.push(i as i32);
    }
    v
}

fn empty_vec() -> Vec<i32> {
    Vec::new()
}

fn empty_string() -> String {
    String::new()
}

fn _db_pattern(conn: &Conn) {
    for row in 0..10 {
        let _ = conn.execute("INSERT INTO t VALUES (?)", &[&row]);
    }
}

#[allow(dead_code)]
struct Conn;

#[allow(dead_code)]
impl Conn {
    fn execute(&self, _q: &str, _p: &[&i32]) -> Result<usize, ()> { Ok(0) }
}

fn _hot(items: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    for s in items {
        out.push(s.clone());
    }
    out
}

#[allow(dead_code)]
fn _holders() {
    let _ = ffi_export();
    let _ = build_vec(10);
    let _ = _hot(&[]);
}
