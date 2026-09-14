#!/usr/bin/env python3
"""Avvia fino a due modelli nello stesso container e li mette dietro una sola porta.

Container Apps espone una porta sola per app, e una sidecar non vede la GPU: se si
vogliono due modelli sulla stessa scheda devono stare qui dentro. Ogni slot dichiara
il tipo (llama o higgs), da dove scende il modello e i suoi argomenti; nginx davanti
smista per percorso.
"""
import os
import shlex
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

import scarica

MODELLI = "/tmp/modelli"
PORTA = int(os.environ.get("PORTA", "8080"))
PORTE_INTERNE = {"A": 8081, "B": 8082}
LLAMA = "/app/llama-server"
HIGGS_DEFAULT = "bosonai/higgs-tts-3-4b"

processi = []


def log(m):
    print(f"[avvia] {m}", flush=True)


def var(slot, nome, default=None):
    return os.environ.get(f"{slot}_{nome}", default)


def ambiente_slot(slot):
    """Le LLAMA_ARG_* con prefisso valgono solo per quello slot: due llama non si pestano."""
    amb = dict(os.environ)
    prefisso = f"{slot}_LLAMA_ARG_"
    for chiave, valore in os.environ.items():
        if chiave.startswith(prefisso):
            amb["LLAMA_ARG_" + chiave[len(prefisso):]] = valore
    return amb


def scarica_modello(slot):
    """Porta giu' il modello dello slot e torna il percorso del file principale."""
    cartella = os.path.join(MODELLI, slot.lower())
    os.makedirs(cartella, exist_ok=True)
    url = var(slot, "URL")
    if url:
        dest = os.path.join(cartella, "modello.gguf")
        scarica.porta_giu(url, dest)
        return dest
    repo, nome = var(slot, "REPO"), var(slot, "FILE")
    if not repo or not nome:
        raise SystemExit(f"slot {slot}: servono {slot}_REPO e {slot}_FILE (oppure {slot}_URL)")
    return scarica.gguf_multiparte(repo, nome, cartella, var(slot, "REVISIONE"))


def avvia_llama(slot, modello, porta):
    amb = ambiente_slot(slot)
    amb["LLAMA_ARG_MODEL"] = modello
    amb["LLAMA_ARG_PORT"] = str(porta)
    amb["LLAMA_ARG_HOST"] = "127.0.0.1"
    for chiave in ("LLAMA_ARG_HF_REPO", "LLAMA_ARG_HF_FILE", "LLAMA_ARG_MODEL_URL"):
        amb.pop(chiave, None)
    comando = [LLAMA] + shlex.split(var(slot, "ARGS", ""))
    log(f"slot {slot}: llama-server sulla {porta}")
    return subprocess.Popen(comando, env=amb), f"http://127.0.0.1:{porta}/health"


def avvia_higgs(slot, porta):
    """sgl-omni si tira giu' i pesi da solo: questo slot non passa da scarica.py."""
    modello = var(slot, "MODELLO", HIGGS_DEFAULT)
    comando = ["sgl-omni", "serve", "--model-path", modello,
               "--port", str(porta), "--host", "127.0.0.1"]
    comando += shlex.split(var(slot, "ARGS", ""))
    log(f"slot {slot}: sgl-omni sulla {porta} con {modello}")
    return subprocess.Popen(comando, env=dict(os.environ)), f"http://127.0.0.1:{porta}/v1/models"


def aspetta(url, processo, minuti=20):
    """Non basta che il processo viva: la porta deve rispondere prima di aprire nginx."""
    scadenza = time.time() + minuti * 60
    while time.time() < scadenza:
        if processo.poll() is not None:
            raise SystemExit(f"il modello e' morto durante l'avvio (uscita {processo.returncode})")
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    return
        except Exception:
            pass
        time.sleep(3)
    raise SystemExit(f"{url} non ha risposto entro {minuti} minuti")


def scrivi_nginx(rotte, principale):
    """Una sola porta esposta: /v1/audio e /tts al TTS, tutto il resto all'LLM."""
    blocchi = []
    for prefisso, porta, *resto in rotte:
        # la barra finale in proxy_pass riscrive il percorso: serve a /tts/ui,
        # che deve arrivare sulla radice del TTS dove sta la sua interfaccia
        destinazione = resto[0] if resto else ""
        blocchi.append(f"""
        location {prefisso} {{
            proxy_pass http://127.0.0.1:{porta}{destinazione};
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }}""")
    conf = f"""
daemon off;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events {{ worker_connections 1024; }}
http {{
    access_log off;
    client_body_temp_path /tmp/nginx-body;
    proxy_temp_path /tmp/nginx-proxy;
    fastcgi_temp_path /tmp/nginx-fastcgi;
    uwsgi_temp_path /tmp/nginx-uwsgi;
    scgi_temp_path /tmp/nginx-scgi;
    client_max_body_size 256m;
    server {{
        listen {PORTA};
        {''.join(blocchi)}
        location / {{
            proxy_pass http://127.0.0.1:{principale};
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_buffering off;
            proxy_read_timeout 3600s;
        }}
    }}
}}
"""
    with open("/tmp/nginx.conf", "w") as f:
        f.write(conf)


def chiudi(*_):
    for p in processi:
        if p.poll() is None:
            p.terminate()
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, chiudi)
    signal.signal(signal.SIGINT, chiudi)
    os.makedirs(MODELLI, exist_ok=True)

    attivi = {}
    for slot in ("A", "B"):
        tipo = (var(slot, "TIPO", "") or "").strip().lower()
        if tipo in ("", "off", "no"):
            continue
        if tipo not in ("llama", "higgs"):
            raise SystemExit(f"slot {slot}: tipo '{tipo}' sconosciuto, valgono llama e higgs")
        attivi[slot] = tipo
    if not attivi:
        raise SystemExit("nessuno slot acceso: serve almeno A_TIPO")

    # i download uno per volta: in parallelo si dividono la banda e non si guadagna niente
    sonde = {}
    for slot, tipo in attivi.items():
        porta = PORTE_INTERNE[slot]
        if tipo == "higgs":
            processo, sonda = avvia_higgs(slot, porta)
        else:
            processo, sonda = avvia_llama(slot, scarica_modello(slot), porta)
        processi.append(processo)
        sonde[slot] = (processo, sonda, tipo, porta)

    for slot, (processo, sonda, tipo, _) in sonde.items():
        log(f"slot {slot}: attendo {sonda}")
        aspetta(sonda, processo)
        log(f"slot {slot}: pronto")

    rotte, principale = [], None
    for slot, (_, _, tipo, porta) in sonde.items():
        if tipo == "higgs":
            # sgl-omni parla solo OpenAI: niente /tts, niente interfaccia
            rotte += [("/v1/audio/", porta)]
        else:
            principale = porta
    if principale is None:  # solo TTS: prende lui la radice, web UI compresa
        principale = next(p for _, (_, _, _, p) in sonde.items())
    scrivi_nginx(rotte, principale)

    log(f"tutto pronto, apro la porta {PORTA}")
    nginx = subprocess.Popen(["nginx", "-c", "/tmp/nginx.conf"])
    processi.append(nginx)

    # se cade un pezzo si chiude tutto: meglio un riavvio pulito della replica che mezzo servizio
    while True:
        for p in processi:
            if p.poll() is not None:
                log(f"un processo e' uscito con {p.returncode}: chiudo tutto")
                chiudi()
        time.sleep(5)


if __name__ == "__main__":
    main()
