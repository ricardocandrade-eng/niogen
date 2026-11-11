# NIOGEN | portal/Dockerfile | 05/11/2026 — Claude Code (prompt nº 16)
# 11/11/2026: + credito.py (operador de crédito, consulta-só) e testar_travas.py.
# Imagem do login do portal PAP: Chromium do Playwright + o pacote Python na mesma versão. Sem segredo na imagem.
FROM mcr.microsoft.com/playwright/python:v1.48.0-jammy
RUN pip install --no-cache-dir playwright==1.48.0
WORKDIR /app
COPY portal_login.py servico.py credito.py testar_travas.py ./
USER pwuser
EXPOSE 8090
CMD ["python", "servico.py"]
