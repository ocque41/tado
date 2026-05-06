// Minimal Go fixture for perf-suite adapter testing. Hits the Go
// adapter's DB-query and xproc-roundtrip regex patterns.
package main

import (
	"database/sql"
	"net/http"
)

func fetchAll(urls []string) []*http.Response {
	out := []*http.Response{}
	for _, u := range urls {
		r, _ := http.Get(u)
		out = append(out, r)
	}
	return out
}

func insertAll(db *sql.DB, ids []int) {
	for _, id := range ids {
		_, _ = db.Exec("INSERT INTO t VALUES (?)", id)
	}
}

func main() {}
