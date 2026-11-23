# NIOGEN | tests/nfse_danfse_test.py | 23/11/2026 — Claude Code (Opus 5.5)
# Gera o DANFSe (nfse/danfse.py) de uma NFS-e FICTÍCIA (a DPS do emissor + o envelope infNFSe como a Sefin devolve) e confere:
# valores e textos no PDF, faixa "SEM VALOR FISCAL" em homologação, uma página só e o QR code apontando para a Consulta Pública.
# Rodar: python tests/nfse_danfse_test.py
import datetime as dt
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'nfse'))
import danfse as D  # noqa: E402
import emissor as E  # noqa: E402
import pymupdf  # noqa: E402
from lxml import etree  # noqa: E402

CFG = {
    'prestador': {'cnpj': '11222333000181', 'cod_municipio': '3136702', 'fone': '32999990000', 'email': 'teste@exemplo.com',
                  'op_simples_nacional': 1, 'reg_esp_trib': 0},
    'tomador': {'cnpj': '44555666000177', 'nome': 'TOMADOR DE TESTE S.A.', 'cod_municipio': '2704302', 'cep': '57000000',
                'logradouro': 'RUA DE TESTE', 'numero': '100', 'complemento': 'SALA 1', 'bairro': 'CENTRO'},
    'servico': {'cod_trib_nacional': '100101', 'cod_trib_municipal': '002', 'tributos_aprox_pct': {'federal': 1, 'estadual': 1, 'municipal': 1}},
}
CHAVE = '3136702' + '2' + '11222333000181' + '0' * 28   # 50 posições (fictícia)
falhas = []


def confere(nome, cond, det=''):
    print(('ok   ' if cond else 'FALHA') + ' ' + nome + (f' — {det}' if det and not cond else ''))
    if not cond:
        falhas.append(nome)


def nfse_ficticia(tp_amb):
    dps = E.montar_dps(CFG, ambiente='restrita' if tp_amb == '2' else 'producao', serie='1', numero='7', valor='1234.5',
                       competencia='2026-11-18', itens=[('4500000001', '10'), ('4500000002', '20')],
                       emissao=dt.datetime(2026, 11, 18, 10, 0, tzinfo=E.SP))
    N = E.NS
    raiz = etree.Element(f'{{{N}}}NFSe', nsmap={None: N}, versao='1.01')
    inf = etree.SubElement(raiz, f'{{{N}}}infNFSe', Id='NFS' + CHAVE)
    for tag, v in [('xLocEmi', 'Juiz de Fora'), ('xLocPrestacao', 'Juiz de Fora'), ('nNFSe', '7'), ('cLocIncid', '3136702'),
                   ('xLocIncid', 'Juiz de Fora'), ('xTribNac', 'Serviço de teste.'), ('xTribMun', 'Serviço de teste'),
                   ('verAplic', 'teste'), ('ambGer', '2'), ('tpEmis', '1'), ('procEmi', '1'), ('cStat', '100'),
                   ('dhProc', '2026-11-18T10:00:05-03:00'), ('nDFSe', '1')]:
        etree.SubElement(inf, f'{{{N}}}{tag}').text = v
    em = etree.SubElement(inf, f'{{{N}}}emit')
    for tag, v in [('CNPJ', '11222333000181'), ('xNome', 'PRESTADOR DE TESTE LTDA')]:
        etree.SubElement(em, f'{{{N}}}{tag}').text = v
    en = etree.SubElement(em, f'{{{N}}}enderNac')
    for tag, v in [('xLgr', 'AV DE TESTE'), ('nro', '1'), ('xBairro', 'CENTRO'), ('cMun', '3136702'), ('UF', 'MG'), ('CEP', '36000000')]:
        etree.SubElement(en, f'{{{N}}}{tag}').text = v
    va = etree.SubElement(inf, f'{{{N}}}valores')
    for tag, v in [('vBC', '1234.50'), ('pAliqAplic', '5.00'), ('vISSQN', '61.73'), ('vLiq', '1234.50')]:
        etree.SubElement(va, f'{{{N}}}{tag}').text = v
    inf.append(dps)
    return etree.tostring(raiz, xml_declaration=True, encoding='UTF-8')


for tp in ('2', '1'):
    pdf, n = D.gerar_pdf(nfse_ficticia(tp))
    doc = pymupdf.open(stream=pdf, filetype='pdf')
    t = doc[0].get_text()
    confere(f'[tpAmb {tp}] uma página A4', len(doc) == 1 and round(doc[0].rect.width) == 595 and round(doc[0].rect.height) == 842)
    for k in ['R$ 1.234,50', 'R$ 61,73', '5,00 %', 'PEDIDO DE COMPRA: 4500000001 ITEM: 10', 'PEDIDO DE COMPRA: 4500000002 ITEM: 20',
              '11.222.333/0001-81', '44.555.666/0001-77', 'TOMADOR DE TESTE S.A.', '10.01.01 / 002', CHAVE, '18/11/2026',
              'Federais: 1,00 %']:
        confere(f'[tpAmb {tp}] PDF traz {k}', k in t)
    confere(f'[tpAmb {tp}] faixa SEM VALOR FISCAL só em homologação', ('SEM VALOR FISCAL' in t) == (tp == '2'))
    try:
        import cv2
        import numpy as np
        pix = doc[0].get_pixmap(dpi=300, clip=pymupdf.Rect(480, 40, 550, 115))
        a = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.h, pix.w, pix.n)
        lido = cv2.QRCodeDetector().detectAndDecode(a)[0]
        confere(f'[tpAmb {tp}] QR = Consulta Pública com a chave', lido == D.CONSULTA.format(CHAVE), lido)
    except ImportError:
        print('aviso: opencv não instalado, QR não conferido')

print(f'\n{"TUDO VERDE" if not falhas else str(len(falhas)) + " FALHA(S): " + ", ".join(falhas)}')
sys.exit(1 if falhas else 0)
