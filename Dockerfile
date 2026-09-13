# llama.cpp e (a scelta) un TTS nello stesso container, dietro una porta sola.
# Container Apps espone una porta per app e nega la GPU alle sidecar: l'unico modo di
# far convivere un LLM e un TTS sulla stessa scheda e' metterli nello stesso container.
#
# Non si parte dall'immagine di llama.cpp: quella si porta dentro tutto
# cuda-libraries-12-8 (3,1 GB) piu' mesa, vulkan e libLLVM, mentre ldd su tutti i
# binari dice che servono soltanto libcublas, libcublasLt e libnccl -- quest'ultima
# e' un DT_NEEDED di libggml-cuda.so e non si toglie. Cosi' sono 1,75 GB invece di 4,8.
FROM nvidia/cuda:12.8.1-base-ubuntu24.04
LABEL org.opencontainers.image.source="https://github.com/rikithedeath/llmduo"
LABEL org.opencontainers.image.description="llama.cpp dietro nginx, due slot, pronto per un secondo motore sulla stessa GPU"

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
