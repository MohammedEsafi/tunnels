#!/bin/sh
# Services inside the test machine, each on its own port:
#   8080  web    a page that says which machine and port answered
#   8081  api    JSON, same idea
#   7777  echo   TCP echo (try: nc 127.0.0.1 <local port>)
#   9999  slow   accepts and then says nothing, for timeout testing
set -e
mkdir -p /srv/web /srv/api
HOST="$(hostname)"
cat > /srv/web/index.html <<EOF
<!doctype html><title>web on $HOST</title>
<body style="font-family:system-ui;padding:40px">
<h1>web · port 8080 · $HOST</h1>
<p>If you can read this, the forward works.</p>
EOF
printf '{"service":"api","port":8081,"host":"%s"}\n' "$HOST" > /srv/api/index.json

( cd /srv/web && exec python3 -m http.server 8080 --bind 0.0.0.0 >/var/log/web.log 2>&1 ) &
( cd /srv/api && exec python3 -m http.server 8081 --bind 0.0.0.0 >/var/log/api.log 2>&1 ) &
( while true; do nc -l -p 7777 -k -e /bin/cat 2>/dev/null || nc -l -p 7777 -k; done ) &
( while true; do nc -l -p 9999 -k >/dev/null 2>&1; done ) &
wait
