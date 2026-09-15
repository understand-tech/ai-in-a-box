import os
import pty
import select
import subprocess
import sys

script, answer = sys.argv[1], sys.argv[2]

master, slave = pty.openpty()
child = subprocess.Popen(["bash", script], stdin=slave, stdout=slave, stderr=slave,
                         close_fds=True)
os.close(slave)
os.write(master, (answer + "\n").encode())

output = b""
while True:
    ready, _, _ = select.select([master], [], [], 15)
    if not ready:
        break
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    output += chunk

child.wait(timeout=15)
os.close(master)
sys.stdout.write(output.decode(errors="replace"))
