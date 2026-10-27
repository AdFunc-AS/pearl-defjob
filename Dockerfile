# Bildet for vast default job. Inneholder BARE oppstartsskriptet, ingen miner og ingen hemmeligheter, så det kan ligge
# i et offentlig register. Mineren hentes og hash-sjekkes ved oppstart (se entrypoint.sh).
#
# sm_120 (RTX 5090) krever CUDA 12.8 eller nyere. Verten har driver 595 (open) og CUDA 13.2.
FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tar xz-utils unzip procps \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/pearl-entrypoint
COPY profiles/ /usr/local/share/pearl/profiles/
RUN chmod 0755 /usr/local/bin/pearl-entrypoint \
 && useradd --create-home --uid 10001 miner

# Uten root kan ikke mineren stille klokker eller effektgrense på kortet (en klokkeforskyvning på et ledig kort kan henge det).
USER 10001
WORKDIR /home/miner
ENTRYPOINT ["/usr/local/bin/pearl-entrypoint"]

LABEL org.opencontainers.image.source="https://github.com/AdFunc-AS/pearl-defjob" \
      org.opencontainers.image.title="pearl-defjob" \
      org.opencontainers.image.description="Henter og hash-sjekker en miner ved oppstart og kjører den på én GPU (vast default job). Ingen miner og ingen hemmeligheter i bildet."
