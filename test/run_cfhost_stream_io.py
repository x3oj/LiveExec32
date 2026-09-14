"""Compare native and ARM32 CFHost I/O against a controlled HTTP server."""
import argparse
import http.server
import os
import subprocess
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"LC32-CFHOST-IO-OK\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def run(command, case, diagnose=False):
    print("Testing:", *command, *case, flush=True)
    env = os.environ.copy()
    if diagnose:
        # Only synthetic localhost requests: never enable verbose tracing
        # for requests containing a user's authentication data.
        env.update(LC32_BLOCK_TRACE="1", LC32_NETWORK_TRACE="1", LC32_OPERATION_TRACE="1")
    process = subprocess.Popen(command + case, env=env)
    try:
        return process.wait(timeout=25) == 0
    except subprocess.TimeoutExpired:
        if diagnose:
            try:
                subprocess.run(["sample", str(process.pid), "1", "1"], timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                pass
        print("FAIL: stream transfer timed out", flush=True)
        return False
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", required=True)
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--guest", required=True)
    parser.add_argument("--probe-host")
    parser.add_argument("--urlconnection-native")
    parser.add_argument("--urlconnection-guest")
    args = parser.parse_args()
    native = [args.native]
    guest = [args.launcher, args.guest]
    failures = 0
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = str(server.server_port)
        cases = [
            ["127.0.0.1", port, "plain", "callbacks", "marker", "deferred"],
            ["localhost", port, "plain", "callbacks", "marker", "deferred"],
            ["localhost", port, "plain", "poll", "marker", "resolved"],
        ]
        try:
            if args.urlconnection_native and args.urlconnection_guest:
                url = [f"http://127.0.0.1:{port}/"]
                failures += not run([args.urlconnection_native], url)
                failures += not run([args.launcher, args.urlconnection_guest], url, diagnose=True)
            for case in cases:
                failures += not run(native, case)
                failures += not run(guest, case)
            if args.probe_host:
                for protocol, port in [("plain", "80"), ("tls", "443")]:
                    case = [args.probe_host, port, protocol, "callbacks", "http", "deferred"]
                    native_ok = run(native, case)
                    guest_ok = run(guest, case)
                    if native_ok and not guest_ok:
                        failures += 1
                    elif not native_ok:
                        print("Public probe inconclusive: native transport also failed", flush=True)
        finally:
            server.shutdown()
            thread.join(timeout=5)
    raise SystemExit(failures != 0)


if __name__ == "__main__":
    main()
