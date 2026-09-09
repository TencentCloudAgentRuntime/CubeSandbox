FROM alpine:3.20
RUN apk add --no-cache ca-certificates curl
COPY pvm-host.rpm /installer/
COPY runtime.tar.gz /installer/
RUN sha256sum /installer/runtime.tar.gz | cut -d ' ' -f1 > /installer/version
COPY daemonset-entrypoint.sh daemonset-install.sh daemonset-pvm.sh /installer/
ENTRYPOINT ["/bin/sh", "/installer/daemonset-entrypoint.sh"]
