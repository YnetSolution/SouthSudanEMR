# SSEMR backup service: dumps the OpenMRS database on the schedule set in
# System Administration > Backups, keeps local copies and sends them to a receiving server over SSH.
FROM alpine:3.20

RUN apk add --no-cache bash coreutils gzip mariadb-client openssh-client tzdata findutils

COPY backup-worker.sh /usr/local/bin/backup-worker.sh
RUN chmod +x /usr/local/bin/backup-worker.sh

# /backups: the dump files (bind-mounted from the host). /ssh: the service's SSH key and known hosts.
VOLUME ["/backups", "/ssh"]

HEALTHCHECK --interval=60s --timeout=5s --start-period=120s \
  CMD test -n "$(find /tmp/backup-worker.heartbeat -mmin -3 2>/dev/null)"

ENTRYPOINT ["/usr/local/bin/backup-worker.sh"]
