"""Keygen, as ut-license meets it, on the loopback: each license key is a scenario."""
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, requests_log, certificates = int(sys.argv[1]), sys.argv[2], sys.argv[3]
token = os.environ.get("KEYGEN_TEST_TOKEN", "")
with open(os.path.join(os.path.dirname(certificates), "fingerprint")) as expected:
    fingerprint = expected.read().strip()

VALIDATIONS = {
    "TEST-FRESH": "NO_MACHINE",
    "TEST-REGISTRY": "NO_MACHINE",
    "TEST-ACTIVE": "VALID",
    "TEST-ELSEWHERE": "FINGERPRINT_SCOPE_MISMATCH",
    "TEST-ENDED": "EXPIRED",
    "TEST-SUSPENDED": "SUSPENDED",
}
activated = set()


def on_a_command_line(*secrets):
    for pid in filter(str.isdigit, os.listdir("/proc")):
        if int(pid) == os.getpid():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as cmdline:
                arguments = cmdline.read()
        except OSError:
            continue
        if any(secret and secret.encode() in arguments for secret in secrets):
            return True
    return False


class Keygen(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/vnd.api+json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        sent = json.loads(self.rfile.read(length) or b"{}")
        authorization = self.headers.get("Authorization", "")
        key = authorization[len("License "):] if authorization.startswith("License ") else ""
        path = self.path.split("/v1/accounts/", 1)[-1].partition("/")[2].partition("?")[0]
        with open(requests_log, "a") as log:
            log.write(f"POST {path}\n")
            if on_a_command_line(key, token):
                log.write("SECRET_ON_A_COMMAND_LINE\n")

        if path == "licenses/actions/validate-key":
            if sent.get("meta", {}).get("key") != key:
                return self.answer(400, {"errors": [{"code": "KEY_MISMATCH"}]})
            code = "VALID" if key in activated else VALIDATIONS.get(key, "NOT_FOUND")
            if code in ("VALID", "NO_MACHINE") and sent["meta"].get("scope", {}).get("fingerprint") != fingerprint:
                code = "FINGERPRINT_SCOPE_MISMATCH"
            if code == "NOT_FOUND":
                return self.answer(200, {"meta": {"valid": False, "code": code}, "data": None})
            expiry = "2020-01-01T00:00:00.000Z" if code == "EXPIRED" else None
            return self.answer(200, {"meta": {"valid": code == "VALID", "code": code},
                                     "data": {"id": "license-" + hashlib.sha256(key.encode()).hexdigest()[:12], "type": "licenses",
                                              "attributes": {"expiry": expiry}}})
        if path == "machines":
            if VALIDATIONS.get(key) == "FINGERPRINT_SCOPE_MISMATCH":
                return self.answer(422, {"errors": [{"code": "MACHINE_LIMIT_EXCEEDED"}]})
            if sent.get("data", {}).get("attributes", {}).get("fingerprint") != fingerprint:
                return self.answer(422, {"errors": [{"code": "FINGERPRINT_TAKEN"}]})
            activated.add(key)
            return self.answer(201, {"data": {"id": "machine-1", "type": "machines"}})
        if path.startswith("machines/") and path.endswith("/actions/check-out"):
            if path != f"machines/{fingerprint}/actions/check-out":
                return self.answer(404, {"errors": [{"code": "NOT_FOUND"}]})
            if key not in activated and VALIDATIONS.get(key) != "VALID":
                return self.answer(422, {"errors": [{"code": "NO_MACHINE"}]})
            try:
                with open(f"{certificates}/{key}.lic") as certificate:
                    return self.answer(200, {"data": {"type": "machine-files",
                                                      "attributes": {"certificate": certificate.read()}}})
            except OSError:
                return self.answer(404, {"errors": [{"code": "NOT_FOUND"}]})
        return self.answer(404, {"errors": [{"code": "NOT_FOUND"}]})


HTTPServer(("127.0.0.1", port), Keygen).serve_forever()
