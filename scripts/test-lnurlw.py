#!/usr/bin/env python3
"""
LNURLw end-to-end test for the Boltcard integration (issue #331).

What this does
--------------
1. Starts a local mock LNURLw server (LUD-03 compliant)
2. Exposes it over HTTPS via ngrok (required because our deep link handler
   converts lnurlw:// → https://)
3. Fires a lnurlw:// deep link to the app:
   - macOS: via `open "lnurlw://..."` (no adb needed)
   - Android: via `adb shell am start`
4. Waits for you to tap "Withdraw" in the app
5. Validates the callback: k1 matches, pr= looks like a real bolt11 invoice
6. Prints PASS or FAIL with details

Prerequisites
-------------
macOS (recommended):
  - ecash-app running via `flutter run -d macos`
  - ngrok installed and authenticated  https://ngrok.com/download
  - python3 (standard library only)

Android emulator:
  - adb installed, emulator connected with ecash-app installed
  - ngrok installed and authenticated
  - python3

Usage
-----
    python3 scripts/test-lnurlw.py            # auto-detects macOS or Android
    python3 scripts/test-lnurlw.py --android  # force Android/adb mode
    python3 scripts/test-lnurlw.py --url https://abc123.ngrok.io  # skip ngrok

Flags
-----
    --port PORT      Local server port (default: 8787)
    --timeout SEC    Seconds to wait for the callback (default: 90)
    --url URL        Skip ngrok and use your own HTTPS base URL
    --android        Force Android/adb mode even on macOS
"""

import argparse
import http.server
import json
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

# ── Config ────────────────────────────────────────────────────────────────────

K1 = "testk1boltcard"
DESCRIPTION = "LNURLw E2E test — Boltcard"
MIN_MSATS = 1_000
MAX_MSATS = 100_000

# ── Shared state set by the server, read by the main thread ───────────────────

_result: dict = {"received": False, "k1": None, "pr": None, "error": None}
_result_event = threading.Event()


# ── Mock LNURLw server ────────────────────────────────────────────────────────

class LnurlwHandler(http.server.BaseHTTPRequestHandler):
    public_url: str = ""  # Set after ngrok/URL is known

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/withdraw":
            self._handle_withdraw(params)
        elif parsed.path == "/callback":
            self._handle_callback(params)
        else:
            self._json(404, {"status": "ERROR", "reason": "unknown path"})

    def _handle_withdraw(self, params):
        p = params.get("p", ["(none)"])[0]
        c = params.get("c", ["(none)"])[0]
        _log(f"[server] /withdraw  p={p}  c={c}")
        self._json(200, {
            "tag": "withdrawRequest",
            "callback": f"{self.public_url}/callback",
            "k1": K1,
            "minWithdrawable": MIN_MSATS,
            "maxWithdrawable": MAX_MSATS,
            "defaultDescription": DESCRIPTION,
        })

    def _handle_callback(self, params):
        k1 = params.get("k1", [None])[0]
        pr = params.get("pr", [None])[0]
        _log(f"[server] /callback  k1={k1}  pr={pr[:40] if pr else None}…")

        if k1 != K1:
            _result["error"] = f"k1 mismatch — expected {K1!r}, got {k1!r}"
            _result_event.set()
            self._json(200, {"status": "ERROR", "reason": "k1 mismatch"})
            return

        if not pr or not any(pr.startswith(p) for p in ("lnbc", "lntb", "lnbcrt")):
            _result["error"] = f"pr does not look like a bolt11 invoice: {pr!r}"
            _result_event.set()
            self._json(200, {"status": "ERROR", "reason": "bad invoice"})
            return

        _result["received"] = True
        _result["k1"] = k1
        _result["pr"] = pr
        _result_event.set()
        self._json(200, {"status": "OK"})

    def _json(self, code: int, body: dict):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass  # suppress default HTTP log noise


# ── Helpers ───────────────────────────────────────────────────────────────────

def _log(msg: str):
    print(msg, flush=True)


def is_macos_mode(force_android: bool) -> bool:
    return sys.platform == "darwin" and not force_android


def check_prereqs(skip_ngrok: bool, force_android: bool):
    errors = []

    if not is_macos_mode(force_android):
        try:
            out = subprocess.check_output(
                ["adb", "devices"], stderr=subprocess.DEVNULL
            ).decode()
            devices = [
                l for l in out.strip().splitlines()[1:]
                if l.strip() and "offline" not in l
            ]
            if not devices:
                errors.append(
                    "No Android device/emulator connected — run `adb devices` to check"
                )
        except FileNotFoundError:
            errors.append("adb not found — install Android SDK platform-tools")

    if not skip_ngrok:
        try:
            subprocess.check_output(
                ["ngrok", "version"], stderr=subprocess.DEVNULL
            )
        except FileNotFoundError:
            errors.append(
                "ngrok not found — install from https://ngrok.com/download\n"
                "  Or skip ngrok with --url https://your-https-endpoint.com"
            )

    if errors:
        print("\nPrerequisite check failed:")
        for e in errors:
            print(f"  ✗ {e}")
        sys.exit(1)


def start_ngrok(port: int) -> tuple:
    """Start ngrok and return (process, https_url)."""
    proc = subprocess.Popen(
        ["ngrok", "http", str(port)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    # Poll the ngrok local API (more reliable than parsing stdout)
    deadline = time.time() + 20
    while time.time() < deadline:
        time.sleep(0.5)
        try:
            with urllib.request.urlopen(
                "http://localhost:4040/api/tunnels", timeout=2
            ) as resp:
                data = json.loads(resp.read())
                for tunnel in data.get("tunnels", []):
                    url = tunnel.get("public_url", "")
                    if url.startswith("https://"):
                        return proc, url
        except Exception:
            pass

    proc.terminate()
    raise RuntimeError(
        "ngrok failed to start within 20 seconds.\n"
        "  Check your auth token: https://dashboard.ngrok.com/get-started/your-authtoken\n"
        "  Or use --url to supply your own HTTPS tunnel URL."
    )


def fire_deep_link(ngrok_url: str, force_android: bool):
    """Send lnurlw:// deep link to the app — via `open` on macOS or adb on Android."""
    host_and_path = ngrok_url.removeprefix("https://")
    deep_link = f"lnurlw://{host_and_path}/withdraw?p=TESTPARAM&c=TESTCMAC"

    if is_macos_mode(force_android):
        _log(f"[open]   Firing: {deep_link}")
        subprocess.run(["open", deep_link], check=True)
    else:
        _log(f"[adb]    Firing: {deep_link}")
        subprocess.run(
            [
                "adb", "shell", "am", "start",
                "-a", "android.intent.action.VIEW",
                "-d", deep_link,
            ],
            check=True,
            capture_output=True,
        )


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8787, help="Local server port (default: 8787)")
    parser.add_argument("--timeout", type=int, default=90, help="Seconds to wait for callback (default: 90)")
    parser.add_argument("--url", default="", help="Skip ngrok; use this HTTPS base URL instead")
    parser.add_argument("--android", action="store_true", help="Force Android/adb mode even on macOS")
    args = parser.parse_args()

    macos = is_macos_mode(args.android)
    platform_label = "macOS" if macos else "Android"

    print("═" * 60)
    print(f"  LNURLw / Boltcard end-to-end test  [{platform_label}]")
    print("═" * 60)
    print()

    check_prereqs(skip_ngrok=bool(args.url), force_android=args.android)

    # Start the mock server
    server = http.server.HTTPServer(("0.0.0.0", args.port), LnurlwHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    _log(f"[server] Listening on port {args.port}")

    ngrok_proc = None
    try:
        if args.url:
            public_url = args.url.rstrip("/")
            _log(f"[tunnel] Using provided URL: {public_url}")
        else:
            _log("[ngrok]  Starting tunnel…")
            ngrok_proc, public_url = start_ngrok(args.port)
            _log(f"[ngrok]  Public URL: {public_url}")

        LnurlwHandler.public_url = public_url

        print()
        _log(f"[{platform_label.lower()}] Sending deep link to app…")
        fire_deep_link(public_url, args.android)

        print()
        print("  ┌─────────────────────────────────────────────────────┐")
        print("  │  The app should now show the Boltcard Withdraw      │")
        print("  │  screen. Tap the 'Withdraw' button to proceed.      │")
        print(f"  │  Waiting up to {args.timeout}s for the callback…               │")
        print("  └─────────────────────────────────────────────────────┘")
        print()

        triggered = _result_event.wait(timeout=args.timeout)

        if not triggered:
            print("FAIL — timeout: the app never called the LNURLw callback.")
            print()
            print("  Possible causes:")
            print("  • App not installed — run `adb install build/app/outputs/flutter-apk/app-debug.apk`")
            print("  • Device screen locked — unlock and retry")
            print("  • Withdraw button not tapped within the timeout")
            print("  • lnurlw:// scheme not registered — check AndroidManifest.xml")
            sys.exit(1)

        if _result["error"]:
            print(f"FAIL — {_result['error']}")
            sys.exit(1)

        print("PASS ✓")
        print()
        print(f"  k1 : {_result['k1']}")
        print(f"  pr : {_result['pr'][:72]}…")
        print()
        print("  The app correctly:")
        print("  1. Fetched withdraw params from the mock server")
        print("  2. Created a real Lightning invoice via the federation")
        print("  3. Called the callback URL with the matching k1 and invoice")
        print()
        print("  Note: no payment will arrive — no Lightning node is paying")
        print("  this invoice. The awaitReceive step in the app will time out.")

    finally:
        if ngrok_proc:
            ngrok_proc.terminate()
        server.shutdown()


if __name__ == "__main__":
    main()
