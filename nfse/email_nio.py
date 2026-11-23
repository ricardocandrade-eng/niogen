# NIOGEN | nfse/email_nio.py | 23/11/2026 — Claude Code (Opus 5.5)
# Envia a NF da comissão à Nio no padrão da mensagem "Comissionamento por PDV" (Ricardo, 23/11/2026: "PDF e e-mail Zoho"):
#   · Para recebimentonfes@…; cópia para o gestor da Nio e a caixa de gestão dos parceiros (endereços na config, fora do repo);
#   · Título = razão social em MAIÚSCULAS, sem acento nem caractere especial, + espaço + ciclo (ex.: "DHARMA TELECOM LTDA 1QNOV26");
#   · Corpo vazio (sem saudação, explicação, imagem ou logo — "não haverá leitura humana");
#   · A NF em PDF anexa; UMA NF por e-mail (um pedido por NF).
# Envio pelo SMTP do Zoho (conta profissional do Ricardo). A senha é a "senha de aplicativo" do Zoho, só na variável de
# ambiente ZOHO_SMTP_SENHA da sessão do terminal — nunca em arquivo, chat ou log (CLAUDE.md, regra 5).
# Mandar à Nio é mandar uma mensagem em nome da Dharma: só com --confirmo. Sem ele, --teste <e-mail> manda a mesma mensagem
# só para esse endereço (sem cópias), para conferir antes.
import argparse
import email.utils
import json
import os
import pathlib
import re
import smtplib
import ssl
import sys
import unicodedata
from email.message import EmailMessage

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from emissor import carregar_config  # noqa: E402


class ErroEmail(Exception):
    pass


def titulo(razao_social, ciclo):
    r = unicodedata.normalize('NFKD', razao_social).encode('ascii', 'ignore').decode().upper()
    r = re.sub(r'[^A-Z0-9 ]', ' ', r)
    r = re.sub(r'\s+', ' ', r).strip()
    c = ciclo.strip().upper()
    if not re.fullmatch(r'[12]Q(JAN|FEV|MAR|ABR|MAI|JUN|JUL|AGO|SET|OUT|NOV|DEZ)\d{2}', c):
        raise ErroEmail(f'Ciclo fora do padrão da Nio (ex.: 1QNOV26): {ciclo}')
    return f'{r} {c}'


def montar(cfg_email, pdf, ciclo, teste=None):
    pdf = pathlib.Path(pdf)
    if not pdf.exists() or pdf.read_bytes()[:5] != b'%PDF-':
        raise ErroEmail(f'O anexo não é um PDF: {pdf}')
    m = EmailMessage()
    m['From'] = cfg_email['remetente']
    if teste:
        m['To'] = teste                                  # teste: só para quem confere, sem cópias
    else:
        m['To'] = ', '.join(cfg_email['para'])
        if cfg_email.get('cc'):
            m['Cc'] = ', '.join(cfg_email['cc'])
    m['Subject'] = titulo(cfg_email['razao_social'], ciclo)
    m['Date'] = email.utils.formatdate(localtime=True)
    m['Message-ID'] = email.utils.make_msgid(domain=cfg_email['remetente'].split('@')[-1])
    m.set_content('')                                    # corpo vazio, como a Nio pede
    m.add_attachment(pdf.read_bytes(), maintype='application', subtype='pdf', filename=pdf.name)
    return m


def enviar(cfg_email, m, host=None):
    senha = os.environ.get('ZOHO_SMTP_SENHA')
    if not senha:
        raise ErroEmail('Defina ZOHO_SMTP_SENHA (senha de aplicativo do Zoho) na sessão do terminal.')
    host = host or cfg_email.get('smtp_host', 'smtppro.zoho.com')
    porta = int(cfg_email.get('smtp_porta', 465))
    with smtplib.SMTP_SSL(host, porta, context=ssl.create_default_context(), timeout=60) as s:
        s.login(cfg_email.get('smtp_usuario', cfg_email['remetente']), senha)
        recusados = s.send_message(m)
    return recusados


def main():
    ap = argparse.ArgumentParser(description='E-mail da NF à Nio (padrão "Comissionamento por PDV"). Nada vai à Nio sem --confirmo.')
    ap.add_argument('--pdf', required=True, help='a NF em PDF (uma por e-mail)')
    ap.add_argument('--ciclo', required=True, help='ex.: 1QNOV26')
    ap.add_argument('--config')
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--teste', metavar='EMAIL', help='manda só para este endereço, sem cópias')
    g.add_argument('--confirmo', action='store_true', help='manda à Nio (para + cópias da config)')
    ap.add_argument('--smtp-host', help='servidor SMTP (padrão: o da config; Zoho: smtppro.zoho.com para conta de empresa, smtp.zoho.com para pessoal)')
    ap.add_argument('--saida', help='pasta para guardar uma cópia .eml do que foi enviado (fora do repo)')
    a = ap.parse_args()
    try:
        cfg = carregar_config(a.config)
        ce = cfg.get('email_nio')
        if not ce or not ce.get('remetente') or not ce.get('para'):
            raise ErroEmail('A config não tem o bloco "email_nio" com remetente e destinatários.')
        m = montar(ce, a.pdf, a.ciclo, a.teste)
        recusados = enviar(ce, m, a.smtp_host)
        if a.saida:
            (pathlib.Path(a.saida) / f'{m["Subject"].replace(" ", "_")}{"_TESTE" if a.teste else ""}.eml').write_bytes(bytes(m))
        print(json.dumps({'enviado': not recusados, 'modo': 'teste' if a.teste else 'nio', 'para': m['To'], 'cc': m['Cc'],
                          'titulo': m['Subject'], 'anexo': pathlib.Path(a.pdf).name, 'recusados': recusados or None},
                         ensure_ascii=False, indent=1))
        return 0 if not recusados else 1
    except (ErroEmail, smtplib.SMTPException, OSError) as e:
        print(json.dumps({'enviado': False, 'erro': f'{type(e).__name__}: {e}', 'smtp': a.smtp_host or (cfg.get('email_nio') or {}).get('smtp_host') if 'cfg' in locals() else None,
                          'senha_tamanho': len(os.environ.get('ZOHO_SMTP_SENHA') or '')}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    sys.exit(main())
