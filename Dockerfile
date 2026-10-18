FROM python:3.13.7-slim-trixie

# podkop-probe can also test servers here, through the router (Global
# settings → Test servers): busybox's sh and tools as on a router, curl, jq
# and podkop-engine-full's sing-box (static, with the SSH outbound)
ARG ENGINE=1.13.21-r14
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends busybox curl jq ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir /opt/busybox && busybox --install -s /opt/busybox \
 && case "${TARGETARCH:-amd64}" in \
      amd64) f=x86_64 sum=7e23ea61e0ce0a58f101706a9bbd3badeea804af165ba12d714cc8c97b753d9d ;; \
      arm64) f=aarch64_generic sum=275e42156a1e36b71310729b6b5557bb2e91aa3c61a68a4f50eb4c61c9ecb7d9 ;; \
      *) echo "no podkop-engine for $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/engine.ipk "https://github.com/FiyeroT/podkop-engine/releases/download/v$ENGINE/podkop-engine-full_${ENGINE}_openwrt_$f.ipk" \
 && echo "$sum  /tmp/engine.ipk" | sha256sum -c - \
 && mkdir /tmp/engine && tar -xzf /tmp/engine.ipk -C /tmp/engine \
 && tar -xzf /tmp/engine/data.tar.gz -C /tmp/engine ./usr/bin/sing-box \
 && install -m 755 /tmp/engine/usr/bin/sing-box /usr/local/bin/sing-box \
 && rm -rf /tmp/engine /tmp/engine.ipk \
 && sing-box version

WORKDIR /app
COPY pyproject.toml ./
COPY podkop_manager podkop_manager
RUN pip install --no-cache-dir . \
 && useradd --system --uid 10001 --home-dir /data podkop-manager \
 && install -d -o podkop-manager -g podkop-manager -m 700 /data
# podkop-agent, install.sh and probe.sh, copied to each router when it's added
COPY router router

ENV PODKOP_MANAGER_DATA=/data PODKOP_MANAGER_SRC=/app \
    PODKOP_MANAGER_PROBE_PATH=/opt/busybox:/usr/local/bin:/usr/bin:/bin
USER podkop-manager
ENTRYPOINT ["podkop-manager"]
CMD ["serve"]
