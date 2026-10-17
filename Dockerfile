FROM python:3.13.7-slim-trixie

WORKDIR /app
COPY pyproject.toml ./
COPY podkop_manager podkop_manager
RUN pip install --no-cache-dir . \
 && useradd --system --uid 10001 --home-dir /data podkop-manager \
 && install -d -o podkop-manager -g podkop-manager -m 700 /data
# podkop-agent, install.sh and probe.sh, copied to each router when it's added
COPY router router

ENV PODKOP_MANAGER_DATA=/data PODKOP_MANAGER_SRC=/app
USER podkop-manager
ENTRYPOINT ["podkop-manager"]
CMD ["serve"]
