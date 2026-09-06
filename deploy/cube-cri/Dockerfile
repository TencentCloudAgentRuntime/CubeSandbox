FROM alpine:3.20
COPY runtime.tar.gz /installer/
RUN sha256sum /installer/runtime.tar.gz | cut -d ' ' -f1 > /installer/version
COPY daemonset-entrypoint.sh daemonset-install.sh /installer/
ENTRYPOINT ["/bin/sh", "/installer/daemonset-entrypoint.sh"]
