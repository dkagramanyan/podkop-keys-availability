FROM python:3.13.7-slim-trixie

# podkop-probe can also test servers here, through the router (Global
# settings → Test servers): busybox's sh and tools as on a router, curl and
# jq. podkop-engine's sing-box is downloaded by the manager into the data
# volume when that is first asked for, so the build doesn't wait for it.
RUN apt-get update && apt-get install -y --no-install-recommends busybox curl jq ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir /opt/busybox && busybox --install -s /opt/busybox

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
