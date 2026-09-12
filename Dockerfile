# Due modelli sulla stessa GPU, dietro una porta sola.
# Container Apps espone una porta per app e nega la GPU alle sidecar: l'unico modo di
# far convivere un LLM e un TTS sulla stessa scheda e' metterli nello stesso container.

# --- stage 1: zonos2.cpp con CUDA -------------------------------------------------
# I binari ufficiali sono solo CPU/Vulkan, e il default CUDA del progetto e' sm_90:
# l'A100 di Container Apps e' sm_80, la T4 sm_75. Si compila qui per tutte e due.
FROM nvidia/cuda:12.6.3-devel-ubuntu24.04 AS zonos

ARG ZONOS_REF=main
RUN apt-get update && apt-get install -y --no-install-recommends \
        git cmake build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ggml e' un sottomodulo: senza --recurse-submodules cmake non trova il suo CMakeLists
RUN git clone --depth 1 --recurse-submodules --shallow-submodules \
        --branch ${ZONOS_REF} https://github.com/Zyphra/zonos2.cpp /src
WORKDIR /src
RUN cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_ARCHITECTURES="75;80" \
    && cmake --build build -j"$(nproc)" --target zonos2-server

# le sue librerie CUDA viaggiano con lui: quelle di llama.cpp restano dove sono
RUN mkdir -p /uscita/lib \
    && cp build/bin/zonos2-server /uscita/ 2>/dev/null || cp build/zonos2-server /uscita/ \
    && cp -a /usr/local/cuda/lib64/libcudart.so.12* /uscita/lib/ \
    && cp -a /usr/local/cuda/lib64/libcublas.so.12* /uscita/lib/ \
    && cp -a /usr/local/cuda/lib64/libcublasLt.so.12* /uscita/lib/

# --- stage 2: immagine finale -----------------------------------------------------
FROM ghcr.io/ggml-org/llama.cpp:server-cuda

LABEL org.opencontainers.image.source="https://github.com/rikithedeath/llmduo"
LABEL org.opencontainers.image.description="llama.cpp + zonos2.cpp: due modelli sulla stessa GPU dietro una porta sola"

# nginx fa da instradatore; ffmpeg serve solo alla clonazione voce di zonos2
RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx-light ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=zonos /uscita/zonos2-server /opt/zonos2/zonos2-server
COPY --from=zonos /uscita/lib/ /opt/zonos2/lib/
COPY scarica.py avvia.py /app/

# Container Apps impone il non-root e inietta un UID qualunque: tutto cio' che si
# scrive deve stare in /tmp, e i file devono essere leggibili da chiunque
RUN chmod -R a+rX /app /opt/zonos2 && chmod a+x /opt/zonos2/zonos2-server
ENV HOME=/tmp \
    PYTHONUNBUFFERED=1 \
    PORTA=8080
USER 1000:1000
WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["/usr/bin/python3", "/app/avvia.py"]
