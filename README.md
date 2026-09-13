# llmduo

Due modelli sulla **stessa GPU**, dietro **una porta sola**: `llama.cpp` per il modello di
linguaggio e [Higgs Audio v3](https://huggingface.co/bosonai/higgs-tts-3-4b) su `sglang-omni`
per la sintesi vocale.

## Perché esiste

Azure Container Apps dà **una GPU per container** — le sidecar non la vedono — ed espone
**una sola porta** per app. Quindi due modelli che devono condividere una scheda vanno
messi nello stesso container, con qualcosa davanti che smisti le richieste. Questo è
quel qualcosa.

## Le due immagini

| tag | scaricato | su disco | cosa c'è |
|---|---|---|---|
| `:latest` | 1,13 GB | 1,75 GB | llama.cpp + nginx + avviatore |
| `:higgs` | 5,15 GB | 10,6 GB | `:latest` + `sglang-omni` potato |

`:latest` **non parte dall'immagine di llama.cpp**: quella porta dentro tutto `cuda-libraries-12-8`
(3,1 GB) più mesa, vulkan e libLLVM, mentre `ldd` sui binari dice che servono solo `libcublas`,
`libcublasLt` e `libnccl`. Si parte da `nvidia/cuda:base`, si installano quelle e si copia `/app`
dall'immagine ufficiale: 1,75 GB invece di 4,8.

`Dockerfile.higgs` aggiunge il TTS, che gira su `sglang-omni` e quindi si tira dietro PyTorch, e
**pota lo stack di sglang nella stessa `RUN` del `pip install`** — cancellare in uno strato
successivo non restituisce un byte, gli strati sono additivi. Se ne vanno mooncake e nixl
(trasferimento KV fra nodi), tilelang, tokenspeed_triton, gradio, diffusers e modelscope, più
pynini, lingua e onnxruntime che sono la normalizzazione del testo e il VAD di *altri* modelli di
sglang-omni, non di Higgs: 17,2 GB scompattati diventano 10,6.

## Gli slot

Due slot, `A` e `B`, ognuno indipendente. Uno solo acceso va benissimo.

| variabile | cosa fa |
|---|---|
| `A_TIPO` / `B_TIPO` | `llama`, `higgs`, oppure vuoto per spegnere lo slot |
| `A_REPO` / `A_FILE` | repo HuggingFace e nome del file GGUF (le serie `-00001-of-000NN` scendono intere) |
| `A_URL` | in alternativa, URL diretto |
| `A_REVISIONE` | branch o tag, default `main` |
| `A_ARGS` | argomenti extra passati al server dello slot |
| `A_LLAMA_ARG_*` | diventa `LLAMA_ARG_*` **solo per quello slot**, così due llama non si pestano |
| `MODELLO_CONNESSIONI` | quante range-request in parallelo, default 8 |
| `PORTA` | porta esposta, default 8080 |

Le `LLAMA_ARG_*` senza prefisso valgono per tutti gli slot `llama`.

## Le rotte

| percorso | dove va |
|---|---|
| `/v1/audio/...` | lo slot `higgs`, se c'è |
| tutto il resto, `/` compresa | lo slot `llama` |

Con il solo TTS acceso prende lui anche la radice. `sgl-omni` parla solo OpenAI:
`/v1/audio/speech` per sintetizzare e `/v1/audio/voices` per caricare una voce da clonare.

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

B_TIPO=higgs
B_MODELLO=bosonai/higgs-tts-3-4b
B_ARGS=--tts_engine.engine.mem_fraction_static=0.30

MODELLO_CONNESSIONI=16
```

Su una A100 80 GB ci stanno comodi: un 26B-A4B Q6_K con contesto 64k più Higgs stanno in
43,8 GB su 81,9. Il tetto di VRAM per `sgl-omni` **non è opzionale**: si alloca una frazione
della memoria libera quando parte, e senza tetto non lascia niente all'altro slot.

## Il download

Il downloader è preso di peso da
[`llama-server-veloce`](https://github.com/rikithedeath/llama-server-veloce): scarica a
**connessioni parallele** invece che a una sola, perché il downloader interno di llama.cpp
ne apre una e basta. Misurato: 11 MB/s contro 95 su Runpod, e 319 MB/s di media verso
Azure Italy North. I file scendono in `/tmp/modelli/<slot>/`. Lo slot `higgs` non passa di
qui: `sgl-omni` si tira giù i pesi da solo.

## Vincoli rispettati

- **Non-root**: Container Apps rifiuta i carichi GPU che girano da root e inietta un UID
  arbitrario. Tutto ciò che si scrive sta in `/tmp`, `HOME` compreso.
- **La porta si apre alla fine**: nginx parte solo quando entrambi gli slot rispondono,
  così la startup probe di Container Apps non vede la porta aperta su un modello che sta
  ancora caricando.
- **Se un pezzo muore, muore tutto**: meglio far riavviare la replica che servire mezzo
  servizio.
- **Niente compilazione CUDA nella build**: i binari di llama.cpp arrivano già fatti
  dall'immagine ufficiale, e sglang compila i suoi kernel all'avvio.
