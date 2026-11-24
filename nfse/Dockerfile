# NIOGEN | nfse/Dockerfile | 23/11/2026 — Claude Code (Opus 5.5)
# Serviço niogen-nfse: emissão da NFS-e (Sefin Nacional), PDF (DANFSe) e e-mail à Nio. Sem segredo na imagem.
FROM python:3.12-slim
# mesmas versões dos testes locais de 23/11/2026 (tests/nfse_*_test.py)
RUN pip install --no-cache-dir lxml==6.1.3 cryptography==48.0.0 requests==2.34.1 pymupdf==1.28.2 segno==1.6.6
RUN useradd -u 10001 -m nfse
WORKDIR /app
COPY emissor.py danfse.py email_nio.py servico.py ./
COPY xsd ./xsd
USER nfse
EXPOSE 8092
CMD ["python", "-u", "servico.py"]
