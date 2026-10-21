"""Keygen as activate-a-machine.sh meets it: one license, found by its metadata, whose
machines it activates under a product token, and whose files it signs with the lab's key."""
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

port, lab, requests_log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
token = os.environ["KEYGEN_PRODUCT_TOKEN"]
machines = {}


def signed_file_for(fingerprint):
    out = os.path.join(lab, f"sent-{fingerprint[:12]}.lic")
    subprocess.run(["bash", "-c", '. /src/test/keygen.sh && signed_machine_file "$1/signing.pem" "$2" "$3" -60 31536000 31536000 ACTIVE',
                    "sign", lab, out, fingerprint], check=True)
    with open(out) as certificate:
        return certificate.read()


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

    def route(self):
        url = urlsplit(self.path)
        path = url.path.split("/v1/accounts/", 1)[-1].partition("/")[2]
        query = parse_qs(url.query)
        with open(requests_log, "a") as log:
            log.write(f"{self.command} {path}\n")
        if self.headers.get("Authorization", "") != "Bearer " + token:
            return self.answer(401, {"errors": [{"code": "TOKEN_INVALID"}]})
        if self.command == "GET" and path == "licenses":
            named = query.get("metadata[customer]") == ["test-customer"] and query.get("metadata[machine]") == ["test-box"]
            return self.answer(200, {"data": [{"id": "license-1", "type": "licenses"}] if named else []})
        if self.command == "POST" and path == "machines":
            sent = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
            fingerprint = sent["data"]["attributes"]["fingerprint"]
            if sent["data"]["relationships"]["license"]["data"]["id"] != "license-1":
                return self.answer(422, {"errors": [{"code": "NOT_FOUND"}]})
            if fingerprint in machines:
                return self.answer(422, {"errors": [{"code": "FINGERPRINT_TAKEN"}]})
            machines[fingerprint] = f"machine-{len(machines) + 1}"
            return self.answer(201, {"data": {"id": machines[fingerprint], "type": "machines"}})
        if self.command == "GET" and path == "machines":
            fingerprint = query.get("fingerprint", [""])[0]
            found = [{"id": machines[fingerprint], "type": "machines"}] if fingerprint in machines else []
            return self.answer(200, {"data": found})
        if self.command == "POST" and path.startswith("machines/") and path.endswith("/actions/check-out"):
            machine_id = path.split("/")[1]
            for fingerprint, known in machines.items():
                if known == machine_id:
                    return self.answer(200, {"data": {"type": "machine-files",
                                                      "attributes": {"certificate": signed_file_for(fingerprint)}}})
            return self.answer(404, {"errors": [{"code": "NOT_FOUND"}]})
        return self.answer(404, {"errors": [{"code": "NOT_FOUND"}]})

    do_GET = do_POST = route


HTTPServer(("127.0.0.1", port), Keygen).serve_forever()
