# A throwaway "remote machine" for testing Tunnels: sshd plus a few services
# on different ports, so every kind of forward can be tried.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server python3 netcat-openbsd ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd

# The user you ssh in as. Key only, no password.
RUN useradd -m -s /bin/bash tester \
 && mkdir -p /home/tester/.ssh \
 && chmod 700 /home/tester/.ssh \
 && chown -R tester:tester /home/tester/.ssh

COPY sshd_config /etc/ssh/sshd_config.d/tunnels.conf
COPY services.sh /usr/local/bin/services.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/services.sh /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
