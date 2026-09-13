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
# libcuda.so e' del driver e in fase di build non esiste: si linka contro lo stub
# dell'immagine devel, e a runtime ci pensa il container toolkit a mettere quella vera.
# -lcuda va messo a mano: la catena cmake di zonos2 non lo aggiunge da sola e ggml-cuda
# resta con i simboli della Driver API (cuMemMap, cuGetErrorString) irrisolti
ENV LIBRARY_PATH=/usr/local/cuda/lib64/stubs
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1 \
    && cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_ARCHITECTURES="75;80" \
        -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs -lcuda" \
        -DCMAKE_SHARED_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs -lcuda" \
    && cmake --build build -j"$(nproc)" --target zonos2-server

# zonos2 si porta dietro il SUO ggml, che non e' quello di llama.cpp: le due copie
# non devono vedersi, per questo stanno in /opt/zonos2/lib e non in un percorso di sistema.
# cuBLAS e cudart no: l'immagine finale ha gia' le sue (12.8, compatibili all'indietro
# con il 12.6 con cui qui si compila) e duplicarle costerebbe 600 MB per niente.
RUN mkdir -p /uscita/lib \
    && cp build/zonos2-server /uscita/ \
    && cp -a build/ggml/src/*.so* /uscita/lib/ \
    && cp -a build/ggml/src/ggml-cuda/*.so* /uscita/lib/ \
    && cp -a /src/web /uscita/web \
    && cp -a /src/emotion_directions /uscita/emotion_directions

# --- stage 2: la base comune, senza zonos2 ----------------------------------------
# Non si parte piu' dall'immagine di llama.cpp: quella si porta dentro tutto
# cuda-libraries-12-8 (3,1 GB) piu' mesa, vulkan e libLLVM, mentre i due motori
# aprono solo cublas, cublasLt e nccl -- verificato con ldd su tutti i binari.
# Dei binari si prende solo /app, che e' dove llama.cpp mette server e librerie.
FROM nvidia/cuda:12.8.1-base-ubuntu24.04 AS nudo

LABEL org.opencontainers.image.source="https://github.com/rikithedeath/llmduo"
LABEL org.opencontainers.image.description="llama.cpp + zonos2.cpp: due modelli sulla stessa GPU dietro una porta sola"

# nginx fa da instradatore; python3 serve all'avviatore e al downloader
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcublas-12-8 libnccl2 libgomp1 python3 nginx-light ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/ggml-org/llama.cpp:server-cuda /app /app
COPY scarica.py avvia.py /app/

# Container Apps impone il non-root e inietta un UID qualunque: tutto cio' che si
# scrive deve stare in /tmp, e i file devono essere leggibili da chiunque
RUN chmod -R a+rX /app
ENV HOME=/tmp \
    PYTHONUNBUFFERED=1 \
    PORTA=8080
USER 1000:1000
WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["/usr/bin/python3", "/app/avvia.py"]

# --- stage 3: immagine di casa, con zonos2 ----------------------------------------
# Sta in coda e non nella base perche' l'immagine con Higgs (Dockerfile.higgs) parte
# da `nudo`: li' zonos2 non si usa, e sono 400 MB di kernel CUDA piu' ffmpeg.
FROM nudo AS completo
USER root

# ffmpeg serve solo alla clonazione voce di zonos2
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY --from=zonos /uscita/zonos2-server /opt/zonos2/zonos2-server
COPY --from=zonos /uscita/lib/ /opt/zonos2/lib/
COPY --from=zonos /uscita/web/ /opt/zonos2/web/
COPY --from=zonos /uscita/emotion_directions/ /opt/zonos2/emotion_directions/
RUN chmod -R a+rX /opt/zonos2 && chmod a+x /opt/zonos2/zonos2-server
USER 1000:1000
