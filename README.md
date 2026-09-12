# llmduo

Due modelli sulla **stessa GPU**, dietro **una porta sola**: `llama.cpp` per il modello di
linguaggio e [`zonos2.cpp`](https://github.com/Zyphra/zonos2.cpp) per la sintesi vocale.

## Perché esiste

Azure Container Apps dà **una GPU per container** — le sidecar non la vedono — ed espone
**una sola porta** per app. Quindi due modelli che devono condividere una scheda vanno
messi nello stesso container, con qualcosa davanti che smisti le richieste. Questo è
quel qualcosa.

Nessun PyTorch: sia llama.cpp sia zonos2.cpp sono C++ su ggml e leggono GGUF. L'immagine
resta intorno ai 3 GB invece dei 10 di uno stack Python, e l'avvio a freddo non ne soffre.

## Gli slot

Due slot, `A` e `B`, ognuno indipendente. Uno solo acceso va benissimo.

| variabile | cosa fa |
|---|---|
| `A_TIPO` / `B_TIPO` | `llama`, `zonos2`, oppure vuoto per spegnere lo slot |
| `A_REPO` / `A_FILE` | repo HuggingFace e nome del file GGUF (le serie `-00001-of-000NN` scendono intere) |
| `A_URL` | in alternativa, URL diretto |
| `A_REVISIONE` | branch o tag, default `main` |
| `A_ARGS` | argomenti extra passati al server dello slot |
| `A_GPU` | `no` per forzare la CPU su quello slot (zonos2); default GPU |
| `A_LLAMA_ARG_*` | diventa `LLAMA_ARG_*` **solo per quello slot**, così due llama non si pestano |
| `MODELLO_CONNESSIONI` | quante range-request in parallelo, default 8 |
| `PORTA` | porta esposta, default 8080 |

Le `LLAMA_ARG_*` senza prefisso valgono per tutti gli slot `llama`.

## Le rotte

| percorso | dove va |
|---|---|
| `/v1/audio/...`, `/tts/...` | lo slot `zonos2`, se c'è |
| tutto il resto, `/` compresa | lo slot `llama` |

Con il solo TTS acceso prende lui anche la radice, web UI inclusa. `zonos2-server` espone
`/v1/audio/speech` (OpenAI-compatibile), `/tts/generate` (PCM in streaming) e
`/tts/capabilities`.

## Esempio

```
A_TIPO=llama
A_REPO=mradermacher/Orion-26B-A4B-v1-GGUF
A_FILE=Orion-26B-A4B-v1.Q5_K_M.gguf
A_ARGS=--reasoning off
A_LLAMA_ARG_CTX_SIZE=49152
A_LLAMA_ARG_N_GPU_LAYERS=999
A_LLAMA_ARG_FLASH_ATTN=on
A_LLAMA_ARG_CACHE_TYPE_K=q8_0
A_LLAMA_ARG_CACHE_TYPE_V=q8_0
A_LLAMA_ARG_ALIAS=orion-26b-a4b

B_TIPO=zonos2
B_REPO=Zyphra/ZONOS2-GGUF
B_FILE=zonos2-q8_0.gguf

MODELLO_CONNESSIONI=16
```

Su una A100 80 GB ci stanno comodi: Orion Q5_K_M con contesto 48k occupa 19,5 GiB,
Zonos2 Q8_0 ne vuole 8,5, e ne restano una cinquantina liberi.

## Il download

Il downloader è preso di peso da
[`llama-server-veloce`](https://github.com/rikithedeath/llama-server-veloce): scarica a
**connessioni parallele** invece che a una sola, perché il downloader interno di llama.cpp
ne apre una e basta. Misurato: 11 MB/s contro 95 su Runpod, e 319 MB/s di media verso
Azure Italy North. I file scendono in `/tmp/modelli/<slot>/` e i tre pezzi di Zonos2
(backbone, `dac.gguf`, `spk-encoder.gguf`) finiscono nella stessa cartella, dove il server
li trova da solo.

## Vincoli rispettati

- **Non-root**: Container Apps rifiuta i carichi GPU che girano da root e inietta un UID
  arbitrario. Tutto ciò che si scrive sta in `/tmp`, `HOME` compreso.
- **La porta si apre alla fine**: nginx parte solo quando entrambi gli slot rispondono,
  così la startup probe di Container Apps non vede la porta aperta su un modello che sta
  ancora caricando.
- **Se un pezzo muore, muore tutto**: meglio far riavviare la replica che servire mezzo
  servizio.
- **CUDA sm_75 e sm_80**: T4 e A100, che sono le due schede dei profili serverless di
  Container Apps. Il default di zonos2.cpp è sm_90 e su A100 non funzionerebbe.
