# pearl-defjob

Docker-bilde som kjører en GPU-miner som bakgrunnsjobb («default job») på vast.ai-verter. Bildet inneholder **bare** oppstartsskriptet [`entrypoint.sh`](entrypoint.sh): ingen miner, ingen lommebok og ingen hemmeligheter.

```
ghcr.io/adfunc-as/pearl-defjob:1
```

## Hvordan det virker

- Mineren hentes fra en URL du velger (`--miner-url`, må være `https://`) og kjøres **bare** hvis SHA-256 stemmer med den du har festet (`--miner-sha256`). Feil hash gir avslutning med kode 65, ingen nye forsøk.
- Bildet kjører som uid 10001 (ikke root), så mineren kan ikke stille klokker eller effektgrense på kortet.
- Workernavnet er `<prefiks>-<8 første tegn av GPU-UUID>`, stabilt mellom pauser og unikt på tvers av maskiner. `{WORKER}` i `--miner-args` byttes ut med det.
- `--miner-args` må stå sist (vast sender alt etter `--args` uendret). SIGTERM stopper mineren (maks 8 sekunders frist), og den startes på nytt med økende ventetid hvis den dør.
- `--selftest` henter og kontrollerer mineren uten å starte den.

```
pearl-entrypoint --miner-url https://… --miner-sha256 <64 hex> --miner-bin <filnavn> [--worker-prefix gpu] \
    --miner-args <argumenter til mineren, {WORKER} byttes ut>
```

## Bruk på vast

I vast-konsollen (Create job → Job to Set) eller med `vastai set defjob <maskin> --price_gpu <pris> --image ghcr.io/adfunc-as/pearl-defjob:1 --args --miner-url … --miner-sha256 … --miner-bin … --miner-args …`. Bare launch type *args* støttes for bakgrunnsjobber. Bildet bygger på `nvidia/cuda:12.8.1-runtime-ubuntu24.04`, så verten trenger driver for CUDA 12.8 eller nyere.

## Bygg

GitHub Actions bygger, røyktester og publiserer ved hver push til `main` ([workflow](.github/workflows/build.yml)). Lokalt: `docker build -t pearl-defjob .`.
