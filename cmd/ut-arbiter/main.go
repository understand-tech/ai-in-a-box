package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

const (
	defaultTTL  = 15 * time.Second
	defaultAddr = "127.0.0.1:8446"
)

const usage = `usage: ut-arbiter <command>

  serve   runs the lease server a pair of boxes contend for, on
          UT_ARBITER_ADDR (default 127.0.0.1:8446). Reachable only through
          Caddy's keyed surface — this process trusts whoever Caddy let
          through, and binds to loopback so nothing else can reach it
          directly.

          POST /lease?id=<box>    acquire or renew, 200 when held, 409 when
                                   somebody else holds it unexpired
          DELETE /lease?id=<box>  give it up early, a no-op for an id that
                                   does not hold it
          GET /lease              read the lease without acquiring it
`

func leaseHandler(lease *Lease, now func() time.Time) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var status LeaseStatus
		switch r.Method {
		case http.MethodGet:
			status = lease.Status(now())
		case http.MethodPost, http.MethodDelete:
			id := r.URL.Query().Get("id")
			if id == "" {
				http.Error(w, "id is required", http.StatusBadRequest)
				return
			}
			if r.Method == http.MethodDelete {
				lease.Release(id, now())
				status = lease.Status(now())
			} else {
				status = lease.Acquire(id, now(), defaultTTL)
			}
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPost && !status.Held {
			w.WriteHeader(http.StatusConflict)
		}
		_ = json.NewEncoder(w).Encode(status)
	}
}

func serveCommand(addr string, now func() time.Time, stdout, stderr io.Writer) int {
	lease := &Lease{}
	mux := http.NewServeMux()
	mux.HandleFunc("/lease", leaseHandler(lease, now))
	fmt.Fprintf(stdout, "ut-arbiter: listening on %s\n", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		fmt.Fprintln(stderr, "ut-arbiter serve:", err)
		return 1
	}
	return 0
}

func fromEnvironment(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func main() {
	args := os.Args[1:]
	if len(args) != 1 || args[0] != "serve" {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	addr := fromEnvironment("UT_ARBITER_ADDR", defaultAddr)
	os.Exit(serveCommand(addr, time.Now, os.Stdout, os.Stderr))
}
