# llmduo

Two models on the **same GPU**, behind **a single port**: `llama.cpp` for the language
model and [Higgs Audio v3](https://huggingface.co/bosonai/higgs-tts-3-4b) on `sglang-omni`
for speech synthesis.

## Why it exists

Azure Container Apps gives you **one GPU per container** — sidecars don't see it — and
exposes **one port** per app. So two models that have to share a card must live in the
same container, with something in front to route the requests. This is that something.

## The image

`ghcr.io/rikithedeath/llmduo`, public. **Two tags, no more**, and they are numbered
(`1.1`, `2.0`…): there is no `:latest`, no `:higgs`, no `:snella`.

| tag | pulled | on disk | what's inside |
|---|---|---|---|
| `:1.0` | 5.02 GB | ~10.6 GB | llama.cpp + nginx + pruned sglang-omni — **the one in service** |
| `:old` | 5.15 GB | — | the previous build, kept **only as a rollback**: point the app at that digest and you're back without rebuilding |

**One `Dockerfile`, two stages.** The `base` stage is llama.cpp with nginx (1.75 GB,
1.13 GB pulled); the second stage adds the TTS on top. `docker build --target base` gives
you the base alone. **There is no published base image, and there must not be one again**:
the TTS stage used to start `FROM` a remote ghcr tag, which is a dependency that can change
under your feet. Today a build needs **this repo only**, plus the public NVIDIA and ggml-org
images.

The base **does not start from the llama.cpp image**: that one drags in the whole of
`cuda-libraries-12-8` (3.1 GB) plus mesa, vulkan and libLLVM, while `ldd` over every binary
says only `libcublas`, `libcublasLt` and `libnccl` are needed. Starting from
`nvidia/cuda:12.8.1-base`, installing those and copying `/app` out of the official image:
1.75 GB instead of 4.8.

The second stage pulls in PyTorch, so it **prunes the sglang stack inside the same `RUN` as
the `pip install`** — deleting in a later layer doesn't give back a single byte, layers are
additive. Out go mooncake, nixl and deep_ep (cross-node KV transfer and MoE dispatch),
tilelang, tokenspeed_triton, gradio, diffusers and modelscope, then pynini, lingua,
onnxruntime, silero_vad, s3prl and nemo_text_processing — text normalisation and VAD
belonging to *other* sglang-omni models, not to Higgs — plus llvmlite+numba, librosa with
its tree and scikit-learn, imageio, z3, the cu12 copy of cutlass and 577 MB of `.pyc`
(`pip install --no-compile`). Their `.dist-info` directories go too, otherwise
`importlib.metadata` keeps claiming the packages are installed. 17.2 GB unpacked come down
to ~10.6.

**Where it gets built**: on a local GPU box, not in Actions — the PyTorch stage wants ten
minutes of `pip` and more disk than a GitHub runner has (13'34" from a cold cache). The
workflow in `.github/workflows/` is `workflow_dispatch` only and is meant for the base stage.

## The slots

Two slots, `A` and `B`, each independent. Running just one is fine.

| variable | what it does |
|---|---|
| `A_TIPO` / `B_TIPO` | `llama`, `higgs`, or empty to switch the slot off |
| `A_REPO` / `A_FILE` | HuggingFace repo and GGUF file name (`-00001-of-000NN` series come down whole) |
| `A_URL` | a direct URL instead |
| `A_REVISIONE` | branch or tag, defaults to `main` |
| `A_MODELLO` | for a `higgs` slot, the model to serve |
| `A_ARGS` | extra arguments passed to that slot's server |
| `A_LLAMA_ARG_*` | becomes `LLAMA_ARG_*` **for that slot only**, so two llamas don't step on each other |
| `MODELLO_CONNESSIONI` | parallel range-requests while downloading, defaults to 8 |
| `MODELLO_PEZZO_MB` / `MODELLO_TENTATIVI` | chunk size (64) and retries per chunk (5) |
| `HF_TOKEN` | sent as a bearer token, for gated or private repos |
| `PORTA` | exposed port, defaults to 8080 |

`LLAMA_ARG_*` without a prefix apply to every `llama` slot.

## The routes

| path | goes to |
|---|---|
| `/v1/audio/...` | the `higgs` slot, if there is one |
| everything else, `/` included | the `llama` slot |

With the TTS alone running, it takes the root as well. `sgl-omni` only speaks OpenAI:
`/v1/audio/speech` to synthesise and `/v1/audio/voices` to upload a voice to clone.

## Example

```
A_TIPO=llama
A_REPO=mradermacher/Goetia-26B-A4B-v1-GGUF
A_FILE=Goetia-26B-A4B-v1.Q6_K.gguf
A_ARGS=--reasoning off
A_LLAMA_ARG_CTX_SIZE=65536
A_LLAMA_ARG_N_GPU_LAYERS=999
A_LLAMA_ARG_FLASH_ATTN=on
A_LLAMA_ARG_CACHE_TYPE_K=q8_0
A_LLAMA_ARG_CACHE_TYPE_V=q8_0
A_LLAMA_ARG_ALIAS=goetia-26b-a4b

B_TIPO=higgs
B_MODELLO=bosonai/higgs-tts-3-4b
B_ARGS=--tts_engine.engine.mem_fraction_static=0.30

MODELLO_CONNESSIONI=16
```

That fits comfortably on an 80 GB A100: a 26B-A4B at Q6_K with a 64k context plus Higgs
take 43.8 GB out of 81.9. The VRAM cap on `sgl-omni` **is not optional**: it grabs a
fraction of whatever is free *when it starts*, both engines start together, and without a
cap it leaves nothing to the other slot. Revisit the value if the other slot's model grows.

**The models are not in the image**: they are picked through the environment and come down
from HuggingFace at startup, so changing model is a new revision, not a build.

## The download

The downloader is lifted wholesale from
[`llama-server-veloce`](https://github.com/rikithedeath/llama-server-veloce): it downloads
over **parallel connections** instead of one, because llama.cpp's built-in downloader opens
a single one. Measured: 11 MB/s against 95 on Runpod, and 319 MB/s average into Azure.
Files land in `/tmp/modelli/<slot>/`. The `higgs` slot doesn't go through this: `sgl-omni`
fetches its own weights.

## Constraints honoured

- **Non-root**: Container Apps refuses GPU workloads running as root and injects an
  arbitrary UID. Everything written lives under `/tmp`, `HOME` included.
- **The port opens last**: nginx only starts once every slot answers, so the Container Apps
  startup probe never finds an open port in front of a model that is still loading.
- **If one piece dies, everything dies**: better to let the replica restart than to serve
  half a service.
- **No CUDA compilation in the build**: llama.cpp binaries arrive prebuilt from the official
  image, and sglang compiles its kernels at startup.
