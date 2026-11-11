# NIOGEN | dfv/Dockerfile | 11/11/2026 — Claude Code (docs/Prompt_operador_dfv_cobertura_111126_1520.md)
# Operador DFV: Chromium do Playwright + o pacote Python na mesma versão. Sem segredo na imagem.
FROM mcr.microsoft.com/playwright/python:v1.48.0-jammy
RUN pip install --no-cache-dir playwright==1.48.0
WORKDIR /app
COPY operador.py ./
USER pwuser
EXPOSE 8091
CMD ["python", "-u", "operador.py"]
