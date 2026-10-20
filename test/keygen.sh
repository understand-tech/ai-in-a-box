#!/usr/bin/env bash
# License files the way Keygen signs them, with a key the suite holds, for a copy
# of ut-license that trusts that key and asks test/fake-keygen.py. Sourced in a
# container that has bash, openssl, jq and python3: the suites run it the same
# way on any machine.

KEYGEN_TEST_PORT=8765
KEYGEN_TEST_SERIAL=TEST-SERIAL-0001
KEYGEN_TEST_TOKEN=${KEYGEN_TEST_TOKEN:-ghp_licenseTestTokenNeverPrinted0001}
KEYGEN_TEST_USER=licensed-user

test_fingerprint() {
    printf '%s' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1
}

# Every program ut-license runs writes its arguments down first, so that a key or
# a token on a command line is seen however short-lived the program is.
programs_that_write_their_arguments_down() {
    local lab=$1 program
    mkdir -p "$lab/argv"
    for program in jq curl openssl sed tr cut head install hostname cat grep mktemp chmod rm; do
        printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> %s/argv.log\nexec %s "$@"\n' \
            "$program" "$lab" "$(command -v "$program")" > "$lab/argv/$program"
        chmod 755 "$lab/argv/$program"
    done
}

signed_machine_file() {
    local signing_key=$1 out=$2 fingerprint=$3 issued_in=$4 expires_in=$5 license_ends_in=$6 status=$7 registry=${8:-}
    local enc
    jq -n --arg fingerprint "$fingerprint" --argjson issued_in "$issued_in" --argjson expires_in "$expires_in" \
        --argjson license_ends_in "$license_ends_in" --arg status "$status" --arg registry "$registry" \
        --arg token "$KEYGEN_TEST_TOKEN" --arg user "$KEYGEN_TEST_USER" '
        def stamp: todate | sub("Z$"; ".000Z");
        {data: {type: "machines", id: "machine-1", attributes: {fingerprint: $fingerprint}},
         included: [{type: "licenses", id: "license-1", attributes: {
             name: "Test box", status: $status, expiry: ((now + $license_ends_in) | stamp),
             metadata: ({customer: "Test Customer", registryUser: $user, registryToken: $token}
                        + (if $registry == "" then {} else {registry: $registry} end))}}],
         meta: {issued: ((now + $issued_in) | stamp), expiry: ((now + $expires_in) | stamp), ttl: 31556952}}' \
        > "$out.json"
    enc=$(openssl base64 -A < "$out.json")
    printf 'machine/%s' "$enc" > "$out.signed"
    openssl pkeyutl -sign -inkey "$signing_key" -rawin -in "$out.signed" -out "$out.sig"
    {
        echo '-----BEGIN MACHINE FILE-----'
        printf '{"enc":"%s","sig":"%s","alg":"base64+ed25519"}' "$enc" "$(openssl base64 -A < "$out.sig")" | openssl base64
        echo '-----END MACHINE FILE-----'
    } > "$out"
    rm -f "$out.json" "$out.signed" "$out.sig"
}

prepare_license_lab() {
    local repo=$1 lab=$2 year=31536000 fingerprint name
    mkdir -p "$lab/keys" "$lab/certificates" "$lab/files"
    openssl genpkey -algorithm ed25519 -out "$lab/signing.pem" 2>/dev/null
    openssl pkey -in "$lab/signing.pem" -pubout -out "$lab/signing.pub"
    openssl genpkey -algorithm ed25519 -out "$lab/other.pem" 2>/dev/null
    printf '%s\n' "$KEYGEN_TEST_SERIAL" > "$lab/serial"
    printf 'test-machine-id\n' > "$lab/machine-id"
    cp "$repo/test/fake-keygen.py" "$lab/"

    printf 'To be filled by O.E.M.\n' > "$lab/placeholder-serial"
    python3 - "$repo/ut-license" "$lab" "$KEYGEN_TEST_PORT" <<'SWAP'
import pathlib, re, sys
original, lab, port = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
for copy, serial in (("ut-license", "serial"), ("ut-license-without-a-serial", "placeholder-serial")):
    text = original.read_text()
    for name, value in (("KEYGEN_API", f"http://127.0.0.1:{port}/v1/accounts/test"),
                        ("KEYGEN_PUBLIC_KEY", (lab / "signing.pub").read_text().strip()),
                        ("SERIAL_FILES", str(lab / serial)),
                        ("MACHINE_ID_FILE", str(lab / "machine-id"))):
        text, count = re.subn(rf"^{name}='[^']*'", f"{name}='{value}'", text, count=1, flags=re.M)
        assert count == 1, name
    (lab / copy).write_text(text)
SWAP
    chmod 755 "$lab/ut-license" "$lab/ut-license-without-a-serial"
    programs_that_write_their_arguments_down "$lab"

    for name in fresh registry active elsewhere ended suspended unknown; do
        printf 'TEST-%s\n' "$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')" > "$lab/keys/$name.key"
    done
    printf 'UT1.dmVyc2lvbj0x.c2lnbmF0dXJl\n' > "$lab/keys/old_format.key"
    printf 'TEST"\nheader = "X-Injected: yes\n' > "$lab/keys/injected.key"

    fingerprint=$(test_fingerprint "serial:${KEYGEN_TEST_SERIAL}")
    printf '%s\n' "$fingerprint" > "$lab/fingerprint"
    signed_machine_file "$lab/signing.pem" "$lab/certificates/TEST-FRESH.lic" "$fingerprint" -60 "$year" "$year" ACTIVE
    signed_machine_file "$lab/signing.pem" "$lab/certificates/TEST-ACTIVE.lic" "$fingerprint" -60 "$year" "$year" ACTIVE
    signed_machine_file "$lab/signing.pem" "$lab/certificates/TEST-REGISTRY.lic" "$fingerprint" -60 "$year" "$year" ACTIVE registry.example.test

    signed_machine_file "$lab/signing.pem" "$lab/files/valid.lic" "$fingerprint" -60 "$year" "$year" ACTIVE
    signed_machine_file "$lab/other.pem" "$lab/files/foreign.lic" "$fingerprint" -60 "$year" "$year" ACTIVE
    signed_machine_file "$lab/signing.pem" "$lab/files/elsewhere.lic" "$(test_fingerprint serial:OTHER-SERIAL-0002)" -60 "$year" "$year" ACTIVE
    signed_machine_file "$lab/signing.pem" "$lab/files/machine_id.lic" "$(test_fingerprint machine-id:test-machine-id)" -60 "$year" "$year" ACTIVE
    signed_machine_file "$lab/signing.pem" "$lab/files/clock.lic" "$fingerprint" 86400 "$year" "$year" ACTIVE
    signed_machine_file "$lab/signing.pem" "$lab/files/ended.lic" "$fingerprint" -$((2 * year)) "$year" -86400 ACTIVE
    signed_machine_file "$lab/signing.pem" "$lab/files/suspended.lic" "$fingerprint" -60 "$year" "$year" SUSPENDED
    signed_machine_file "$lab/signing.pem" "$lab/files/file_ended.lic" "$fingerprint" -$((2 * year)) -86400 "$year" ACTIVE
    python3 - "$lab/files/valid.lic" "$lab/files/tampered.lic" <<'TAMPER'
import base64, json, sys
lines = open(sys.argv[1]).read().split("\n")
envelope = json.loads(base64.b64decode("".join(line for line in lines if not line.startswith("-----"))))
dataset = base64.b64decode(envelope["enc"]).replace(b"Test Customer", b"Someone Else", 1)
envelope["enc"] = base64.b64encode(dataset).decode()
body = base64.encodebytes(json.dumps(envelope).encode()).decode()
open(sys.argv[2], "w").write("-----BEGIN MACHINE FILE-----\n" + body + "-----END MACHINE FILE-----\n")
TAMPER
    printf 'not a license file\n' > "$lab/files/garbage.lic"
    chmod -R a+rX "$lab"
}
