# NIOGEN | tests/nfse_email_test.py | 23/11/2026 — Claude Code (Opus 5.5)
# Monta (sem enviar) o e-mail da NF à Nio com dados fictícios e confere o padrão da mensagem "Comissionamento por PDV".
# Rodar: python tests/nfse_email_test.py
import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'nfse'))
import email_nio as M  # noqa: E402

CE = {'remetente': 'nf@exemplo.com.br', 'razao_social': 'Dharmá Telecom Ltda.', 'para': ['recebe@exemplo.com'],
      'cc': ['gestor@exemplo.com', 'parceiros@exemplo.com']}
falhas = []


def confere(nome, cond, det=''):
    print(('ok   ' if cond else 'FALHA') + ' ' + nome + (f' — {det}' if det and not cond else ''))
    if not cond:
        falhas.append(nome)


pdf = pathlib.Path(tempfile.mkdtemp()) / 'NF_1.pdf'
pdf.write_bytes(b'%PDF-1.4\n%teste\n')
confere('título: MAIÚSCULAS, sem acento nem pontuação + ciclo', M.titulo(CE['razao_social'], '1qnov26') == 'DHARMA TELECOM LTDA 1QNOV26',
        M.titulo(CE['razao_social'], '1qnov26'))
try:
    M.titulo('X', 'NOV26')
    confere('ciclo fora do padrão é recusado', False)
except M.ErroEmail:
    confere('ciclo fora do padrão é recusado', True)

m = M.montar(CE, pdf, '1QNOV26')
partes = list(m.iter_parts())
confere('para a Nio: To e Cc da config', m['To'] == 'recebe@exemplo.com' and m['Cc'] == 'gestor@exemplo.com, parceiros@exemplo.com')
confere('corpo vazio', partes[0].get_content().strip() == '')
anexos = [p for p in partes if p.get_filename()]
confere('um anexo só, o PDF', len(anexos) == 1 and anexos[0].get_content_type() == 'application/pdf' and anexos[0].get_filename() == 'NF_1.pdf')

t = M.montar(CE, pdf, '1QNOV26', teste='eu@exemplo.com')
confere('teste: só para quem confere, sem cópias', t['To'] == 'eu@exemplo.com' and t['Cc'] is None and t['Subject'] == m['Subject'])

ruim = pdf.with_name('nao_e_pdf.pdf')
ruim.write_bytes(b'oi')
try:
    M.montar(CE, ruim, '1QNOV26')
    confere('anexo que não é PDF é recusado', False)
except M.ErroEmail:
    confere('anexo que não é PDF é recusado', True)

print(f'\n{"TUDO VERDE" if not falhas else str(len(falhas)) + " FALHA(S): " + ", ".join(falhas)}')
sys.exit(1 if falhas else 0)
