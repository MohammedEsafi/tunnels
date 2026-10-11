#!/bin/sh
set -e
# authorized_keys is mounted read-only at /keys/authorized_keys by compose.
if [ -f /keys/authorized_keys ]; then
  cp /keys/authorized_keys /home/tester/.ssh/authorized_keys
  chown tester:tester /home/tester/.ssh/authorized_keys
  chmod 600 /home/tester/.ssh/authorized_keys
fi
ssh-keygen -A >/dev/null
/usr/local/bin/services.sh &
exec /usr/sbin/sshd -D -e
