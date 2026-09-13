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

## Le immagini

| tag | cosa c'è | a cosa serve |
|---|---|---|
| `:nudo` | llama.cpp + nginx + avviatore | base per chi ci mette sopra un altro motore |
| `:latest` | `:nudo` + zonos2.cpp + ffmpeg | l'immagine completa, due slot |

La base **non parte dall'immagine di llama.cpp**: quella porta dentro tutto `cuda-libraries-12-8`
(3,1 GB) più mesa, vulkan e libLLVM, mentre `ldd` sui binari dice che servono solo `libcublas`,
`libcublasLt` e `libnccl`. Si parte da `nvidia/cuda:base`, si installano quelle tre e si copia `/app`
dall'immagine ufficiale: 1,7 GB invece di 4,8.

`Dockerfile.higgs` costruisce la variante con [Higgs Audio v3](https://huggingface.co/bosonai/higgs-tts-3-4b)
al posto di zonos2, che gira su `sglang-omni` e quindi si tira dietro PyTorch. Parte da `:nudo`
perché lì lo slot zonos2 non si usa, e **pota lo stack di sglang nella stessa `RUN` del `pip
install`** — cancellare in uno strato successivo non restituisce un byte, gli strati sono additivi.
Se ne vanno mooncake e nixl (trasferimento KV fra nodi), tilelang, tokenspeed_triton, gradio,
diffusers e modelscope, più pynini, lingua e onnxruntime che sono la normalizzazione del testo e il
VAD di *altri* modelli di sglang-omni, non di Higgs: 17,2 GB scompattati diventano 10,6.

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
