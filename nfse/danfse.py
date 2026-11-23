# NIOGEN | nfse/danfse.py | 23/11/2026 — Claude Code (Opus 5.5)
# Gera o PDF da NFS-e (DANFSe — Documento Auxiliar da NFS-e) a partir do XML oficial que a Sefin Nacional devolve na emissão.
# Pedido do Ricardo em 23/11/2026 ("Sim, gerar aqui"): o serviço oficial de PDF do ADN (/danfse) estava fora do ar (503) em
# produção e não existe na produção restrita; o e-mail da NF à Nio não pode ficar preso a ele.
#
# O documento fiscal é o XML (assinado pela Sefin); o DANFSe é só a representação impressa. Este gera a mesma informação do
# DANFSe v2.0 oficial, na mesma ordem e grade (modelo: o PDF oficial da NF nº 1, de 18/11/2026), com o QR code que aponta para a
# Consulta Pública da Receita (o mesmo endereço do QR oficial: https://www.nfse.gov.br/ConsultaPublica?tpc=1&chave=<chave>) —
# quem recebe confere a nota lá. No rodapé diz que foi gerado a partir do XML. Em produção restrita, faixa "SEM VALOR FISCAL".
#
# Uso:  python nfse/danfse.py --xml <NFSe_*.xml> --saida <pasta>
import argparse
import datetime as dt
import io
import json
import pathlib
import sys

import pymupdf
import segno
from lxml import etree

NS = {'n': 'http://www.sped.fazenda.gov.br/nfse'}
CONSULTA = 'https://www.nfse.gov.br/ConsultaPublica?tpc=1&chave={}'

# Nomes dos municípios que o XML não traz por extenso (o do tomador só vem pelo código IBGE). Faltou um: sai o código.
MUNICIPIOS = {'3136702': ('Juiz de Fora', 'MG'), '2704302': ('Maceió', 'AL')}
UF_IBGE = {'11': 'RO', '12': 'AC', '13': 'AM', '14': 'RR', '15': 'PA', '16': 'AP', '17': 'TO', '21': 'MA', '22': 'PI', '23': 'CE',
           '24': 'RN', '25': 'PB', '26': 'PE', '27': 'AL', '28': 'SE', '29': 'BA', '31': 'MG', '32': 'ES', '33': 'RJ', '35': 'SP',
           '41': 'PR', '42': 'SC', '43': 'RS', '50': 'MS', '51': 'MT', '52': 'GO', '53': 'DF'}
SIMPLES = {'1': 'Não optante', '2': 'Optante - MEI', '3': 'Optante - ME/EPP'}
EMITENTE = {'1': 'Prestador', '2': 'Tomador', '3': 'Intermediário'}
TRIB_ISSQN = {'1': 'Operação Tributável', '2': 'Imunidade', '3': 'Exportação de Serviço', '4': 'Não Incidência'}
RET_ISSQN = {'1': 'Não Retido', '2': 'Retido pelo Tomador', '3': 'Retido pelo Intermediário'}
SITUACAO = {'100': 'NFS-e Gerada', '101': 'NFS-e de Substituição Gerada', '102': 'NFS-e de Decisão Judicial', '103': 'NFS-e Avulsa'}

# página A4 e grade de 4 colunas, como o DANFSe oficial (margem 11,9 pt; colunas a cada ~144,6 pt; letra 7 pt)
L, R, TOPO = 11.9, 583.1, 10.3
COL = (R - L) / 4
H_LIN = 19.0
CINZA = (0.92, 0.92, 0.92)


# ───────────────────────── leitura do XML ─────────────────────────
class Nota:
    def __init__(self, xml_bytes):
        self.raiz = etree.fromstring(xml_bytes)
        self.inf = self.raiz.find('n:infNFSe', NS)
        if self.inf is None:
            raise ValueError('O XML não é uma NFS-e (falta infNFSe).')
        self.dps = self.inf.find('n:DPS/n:infDPS', NS)
        self.chave = self.inf.get('Id', '')[3:]

    def t(self, caminho, base=None):
        e = (base if base is not None else self.inf).find(caminho, NS)
        # espaços repetidos no meio do texto (o XML de produção trouxe "TERREO              PAVMTO1") viram um só, como no oficial
        return ' '.join(e.text.split()) if e is not None and e.text and e.text.strip() else None

    def d(self, caminho):
        return self.t(caminho, self.dps)


def cnpj(v):
    v = ''.join(c for c in (v or '') if c.isalnum())
    return f'{v[:2]}.{v[2:5]}.{v[5:8]}/{v[8:12]}-{v[12:]}' if len(v) == 14 else (v or '-')


def cep(v):
    v = ''.join(c for c in (v or '') if c.isdigit())
    return f'{v[:2]}.{v[2:5]}-{v[5:]}' if len(v) == 8 else (v or '-')


def fone(v):
    v = ''.join(c for c in (v or '') if c.isdigit())
    if len(v) == 11:
        return f'({v[:2]}) {v[2:7]}-{v[7:]}'
    if len(v) == 10:
        return f'({v[:2]}) {v[2:6]}-{v[6:]}'
    return v or '-'


def real(v):
    if v in (None, ''):
        return '-'
    s = f'{float(v):,.2f}'.replace(',', 'X').replace('.', ',').replace('X', '.')
    return f'R$ {s}'


def pct(v):
    return '-' if v in (None, '') else f'{float(v):.2f}'.replace('.', ',') + ' %'


def data(v):
    if not v:
        return '-'
    try:
        if 'T' in v:
            x = dt.datetime.fromisoformat(v)
            return x.strftime('%d/%m/%Y %H:%M:%S')
        return dt.date.fromisoformat(v[:10]).strftime('%d/%m/%Y')
    except ValueError:
        return v


def mun(cod):
    cod = (cod or '').strip()
    if cod in MUNICIPIOS:
        return MUNICIPIOS[cod]
    return (cod or '-', UF_IBGE.get(cod[:2], '-'))


def cod_mun(cod):
    cod = (cod or '').strip()
    return f'{cod[:2]}.{cod[2:]}' if len(cod) == 7 else (cod or '-')


def ctrib(v):
    v = (v or '').strip()
    return f'{v[:2]}.{v[2:4]}.{v[4:]}' if len(v) == 6 else (v or '-')


def nz(v):
    return v if v not in (None, '') else '-'


# ───────────────────────── desenho ─────────────────────────
class Folha:
    def __init__(self):
        self.doc = pymupdf.open()
        self.p = self.doc.new_page(width=595, height=842)
        self.y = TOPO

    def texto(self, x, y, s, tam=7, negrito=False, largura=None, alinhar=0):
        fonte = 'hebo' if negrito else 'helv'
        if largura:
            r = pymupdf.Rect(x, y, x + largura, y + 80)   # folgada: insert_textbox não desenha nada se não couber
            self.p.insert_textbox(r, s, fontsize=tam, fontname=fonte, align=alinhar)
        else:
            self.p.insert_text((x, y + tam), s, fontsize=tam, fontname=fonte)

    def linha(self, y):
        self.p.draw_line((L, y), (R, y), color=(0, 0, 0), width=0.6)

    def titulo_secao(self, nome, campos):
        """Faixa cinza com o nome da seção na 1ª coluna e os rótulos/valores dos campos nas outras 3 (como no oficial)."""
        self.p.draw_rect(pymupdf.Rect(L, self.y, L + COL, self.y + H_LIN), color=None, fill=CINZA)
        self.texto(L + 2, self.y + 2, nome, 7 if len(nome) > 24 else 7.5, True, largura=COL - 4)
        campos = list(campos[:3]) + [('', '')] * (3 - len(campos[:3]))
        j = 0
        while j < 3:
            rot, val = campos[j]
            k = j + 1
            while k < 3 and campos[k] == ('', ''):
                k += 1
            if rot:
                self.celula(L + COL * (j + 1), self.y, rot, val, COL * (k - j))
            j = k
        self.y += H_LIN

    def celula(self, x, y, rot, val, largura=COL):
        self.texto(x + 2, y + 1.5, rot, 6.5, True, largura=largura - 4)
        self.texto(x + 2, y + 9.5, val if val not in (None, '') else '-', 7, largura=largura - 4)

    def grade(self, campos):
        """Linhas de até 4 células. ('', '') logo depois de um campo = esse campo ocupa também aquela coluna;
        rótulo começando com * = ocupa até o fim da linha."""
        for i in range(0, len(campos), 4):
            linha = campos[i:i + 4]
            j = 0
            while j < len(linha):
                rot, val = linha[j]
                k = j + 1
                while k < len(linha) and linha[k] == ('', ''):
                    k += 1
                if rot:
                    largura = COL * ((4 - j) if rot.startswith('*') else (k - j))
                    self.celula(L + COL * j, self.y, rot.lstrip('*'), val, largura)
                j = k
            self.y += H_LIN

    def faixa(self, texto):
        self.texto(L, self.y + 1, texto, 7, True, largura=R - L, alinhar=1)
        self.y += 10

    def corrido(self, rot, val, linhas=1):
        topo = self.y
        if rot:
            self.texto(L + 2, self.y + 1.5, rot, 6.5, True, largura=R - L - 4)
            topo += 9.5
        altura = 9 * max(linhas, 1) + 4
        self.p.insert_textbox(pymupdf.Rect(L + 2, topo, R - 2, topo + altura + 20), val or '-', fontsize=7, fontname='helv')
        self.y = topo + altura


def gerar_pdf(xml_bytes):
    n = Nota(xml_bytes)
    d = n.d
    tp_amb = d('n:tpAmb') or '1'
    f = Folha()
    p = f.p

    # cabeçalho
    f.texto(L, TOPO + 4, 'NFS-e', 16, True)
    f.texto(L + 50, TOPO + 6, 'Nota Fiscal de\nServiço eletrônica', 6.5, largura=80)
    f.texto(200, TOPO + 2, 'DANFSe v2.0', 9, True, largura=195, alinhar=1)
    f.texto(200, TOPO + 14, 'Documento Auxiliar da NFS-e', 8, True, largura=195, alinhar=1)
    emit_uf = n.t('n:emit/n:enderNac/n:UF') or mun(d('n:cLocEmi'))[1]
    f.texto(445, TOPO + 2, f'Município: {n.t("n:xLocEmi") or "-"} - {emit_uf}', 8.5, largura=140)
    f.texto(445, TOPO + 13, f'Ambiente Gerador: {nz(n.t("n:ambGer"))}\nTipo de Ambiente: {tp_amb}', 6, largura=140)
    f.y = 40
    if tp_amb == '2':
        p.draw_rect(pymupdf.Rect(L, f.y, R, f.y + 11), color=None, fill=(1, 0.88, 0.88))
        f.texto(L, f.y + 2, 'PRODUÇÃO RESTRITA (HOMOLOGAÇÃO) - SEM VALOR FISCAL', 7.5, True, largura=R - L, alinhar=1)
        f.y += 13
    f.linha(f.y)

    # QR code da Consulta Pública
    qr = io.BytesIO()
    segno.make(CONSULTA.format(n.chave), error='m').save(qr, kind='png', scale=6, border=1)
    yq = f.y + 2
    p.insert_image(pymupdf.Rect(492, yq, 537, yq + 45), stream=qr.getvalue())
    f.texto(445, yq + 47, 'A autenticidade desta NFS-e pode ser verificada pela leitura deste código QR ou pela consulta da chave de '
                          'acesso no portal nacional da NFS-e', 5.5, largura=138, alinhar=1)

    larg3 = COL * 3 - 4
    f.celula(L, f.y, 'CHAVE DE ACESSO DA NFS-e', n.chave, largura=COL * 3)
    f.y += H_LIN
    f.grade([('NÚMERO DA NFS-e', n.t('n:nNFSe')), ('COMPETÊNCIA DA NFS-e', data(d('n:dCompet'))),
             ('DATA E HORA DA EMISSÃO DA NFS-e', data(n.t('n:dhProc')))])
    f.grade([('NÚMERO DA DPS', d('n:nDPS')), ('SÉRIE DA DPS', d('n:serie')), ('DATA E HORA DA EMISSÃO DA DPS', data(d('n:dhEmi')))])
    fin = d('n:finNFSe')
    f.grade([('EMITENTE DA NFS-e', EMITENTE.get(d('n:tpEmit'), d('n:tpEmit'))),
             ('SITUAÇÃO DA NFS-e', SITUACAO.get(n.t('n:cStat'), n.t('n:cStat'))),
             ('FINALIDADE', 'NFS-e regular' if fin == '0' else '-')])
    f.y = max(f.y, yq + 70)
    del larg3

    # prestador (dados do emit da NFS-e; regime tributário da DPS)
    f.linha(f.y)
    em = 'n:emit/n:enderNac/'
    m_e, uf_e = mun(n.t(em + 'n:cMun'))
    f.titulo_secao('PRESTADOR / FORNECEDOR', [('CNPJ / CPF / NIF', cnpj(n.t('n:emit/n:CNPJ') or n.t('n:emit/n:CPF'))),
                                             ('Indicador Municipal (Inscrição)', nz(n.t('n:emit/n:IM'))),
                                             ('Telefone', fone(n.t('n:emit/n:fone')))])
    end_e = ', '.join(x for x in (n.t(em + 'n:xLgr'), n.t(em + 'n:nro'), n.t(em + 'n:xCpl'), n.t(em + 'n:xBairro')) if x)
    f.grade([('Nome / Nome Empresarial', n.t('n:emit/n:xNome')), ('', ''), ('Município / Sigla UF', f'{m_e} / {uf_e}'),
             ('Código IBGE / CEP', f'{cod_mun(n.t(em + "n:cMun"))} / {cep(n.t(em + "n:CEP"))}')])
    f.grade([('Endereço', end_e or '-'), ('', ''), ('E-mail', nz(n.t('n:emit/n:email'))), ('', '')])
    f.grade([('Simples Nacional na Data de Competência', SIMPLES.get(d('n:prest/n:regTrib/n:opSimpNac'), '-')),
             ('Regime de Apuração Tributária pelo SN', nz(d('n:prest/n:regTrib/n:regApTribSN')))])

    # tomador
    f.linha(f.y)
    tm = 'n:toma/n:end/'
    m_t, uf_t = mun(d(tm + 'n:endNac/n:cMun'))
    f.titulo_secao('TOMADOR / ADQUIRENTE', [('CNPJ / CPF / NIF', cnpj(d('n:toma/n:CNPJ') or d('n:toma/n:CPF') or d('n:toma/n:NIF'))),
                                           ('Indicador Municipal (Inscrição)', nz(d('n:toma/n:IM'))),
                                           ('Telefone', fone(d('n:toma/n:fone')))])
    end_t = ', '.join(x for x in (d(tm + 'n:xLgr'), d(tm + 'n:nro'), d(tm + 'n:xCpl'), d(tm + 'n:xBairro')) if x)
    f.grade([('Nome / Nome Empresarial', d('n:toma/n:xNome')), ('', ''), ('Município / Sigla UF', f'{m_t} / {uf_t}'),
             ('Código IBGE / CEP', f'{cod_mun(d(tm + "n:endNac/n:cMun"))} / {cep(d(tm + "n:endNac/n:CEP"))}')])
    f.grade([('Endereço', end_t or '-'), ('', ''), ('E-mail', nz(d('n:toma/n:email'))), ('', '')])
    f.linha(f.y)
    f.faixa('DESTINATÁRIO DA OPERAÇÃO NÃO IDENTIFICADO NA NFS-e')
    f.linha(f.y)
    f.faixa('INTERMEDIÁRIO DA OPERAÇÃO NÃO IDENTIFICADO NA NFS-e' if d('n:interm/n:CNPJ') is None else
            f'INTERMEDIÁRIO: {cnpj(d("n:interm/n:CNPJ"))} {d("n:interm/n:xNome") or ""}')
    f.linha(f.y)

    # serviço
    loc = n.t('n:xLocPrestacao') or '-'
    f.titulo_secao('SERVIÇO PRESTADO', [('Código de Tributação Nacional/Municipal',
                                         f'{ctrib(d("n:serv/n:cServ/n:cTribNac"))} / {nz(d("n:serv/n:cServ/n:cTribMun"))}'),
                                        ('Código da NBS', nz(d('n:serv/n:cServ/n:cNBS'))),
                                        ('Local da Prestação / Sigla UF / País', f'{loc} / {mun(d("n:serv/n:locPrest/n:cLocPrestacao"))[1]} / -')])
    f.texto(L + 2, f.y + 1, n.t('n:xTribMun') or n.t('n:xTribNac') or '-', 7, largura=R - L - 4)
    f.y += 10
    desc = d('n:serv/n:cServ/n:xDescServ') or '-'
    f.corrido('Descrição do Serviço', desc, linhas=desc.count('\n') + 1)

    # tributação municipal
    f.linha(f.y)
    f.titulo_secao('TRIBUTAÇÃO MUNICIPAL (ISSQN)', [
        ('Tipo de Tributação do ISSQN', TRIB_ISSQN.get(d('n:valores/n:trib/n:tribMun/n:tribISSQN'), '-')),
        ('Município / Sigla UF / País de Incidência do ISSQN',
         f'{n.t("n:xLocIncid") or "-"} / {mun(n.t("n:cLocIncid"))[1]} / -'), ('', '')])
    f.grade([('BC ISSQN', real(n.t('n:valores/n:vBC'))), ('Alíquota Aplicada', pct(n.t('n:valores/n:pAliqAplic'))),
             ('Retenção do ISSQN', RET_ISSQN.get(d('n:valores/n:trib/n:tribMun/n:tpRetISSQN'), '-')),
             ('ISSQN Apurado', real(n.t('n:valores/n:vISSQN')))])

    # tributação federal (não informada nas notas da Dharma) e IBS/CBS
    f.linha(f.y)
    f.titulo_secao('TRIBUTAÇÃO FEDERAL (EXCETO CBS)', [('IRRF', real(d('n:valores/n:trib/n:tribFed/n:vRetIRRF'))),
                                                     ('Contribuição Previdenciária - Retida', real(d('n:valores/n:trib/n:tribFed/n:vRetCP'))),
                                                     ('Contribuições Sociais - Retidas', real(d('n:valores/n:trib/n:tribFed/n:vRetCSLL')))])
    pc = 'n:valores/n:trib/n:tribFed/n:piscofins/'
    f.grade([('PIS - Débito Apuração Própria', real(d(pc + 'n:vPis'))), ('COFINS - Débito Apuração Própria', real(d(pc + 'n:vCofins'))),
             ('Descrição Contrib. Sociais - Retidas', nz(d('n:valores/n:trib/n:tribFed/n:xContribSoc')))])
    # IBS/CBS: mesmos campos do DANFSe oficial (as notas da Dharma de 2026 não trazem o grupo; ficam "-")
    ib = 'n:IBSCBS/'
    f.linha(f.y)
    f.titulo_secao('TRIBUTAÇÃO IBS/CBS', [('CST / cClassTrib', f'{nz(d(ib + "n:valores/n:trib/n:CST"))} / '
                                                              f'{nz(d(ib + "n:valores/n:trib/n:cClassTrib"))}'),
                                         ('Indicador de Operação / Código IBGE Incidência / Município Incidência / Sigla UF',
                                          f'{nz(d(ib + "n:cIndOp"))} / {nz(n.t(ib + "n:cLocalidadeIncid"))} / '
                                          f'{nz(n.t(ib + "n:xLocalidadeIncid"))} / -'), ('', '')])
    f.grade([('Exclusões e Reduções da Base de Cálculo', real(n.t(ib + 'n:valores/n:vCalcReeRepRes'))),
             ('Base de Cálculo Após Exclusões e Reduções', real(n.t(ib + 'n:valores/n:vBC'))),
             ('Red. Alíquota IBS / Red. Alíquota CBS', '- / - / -'), ('Alíquota - IBS UF / IBS Mun', '- / -')])
    f.grade([('Alíq. Efetiva Municipal - IBS', '-'), ('Valor Apurado Municipal - IBS', real(n.t(ib + 'n:totCIBS/n:gIBS/n:gIBSMunTot/n:vIBSMun'))),
             ('Alíq. Efetiva Estadual - IBS', '-'), ('Valor Apurado Estadual - IBS', real(n.t(ib + 'n:totCIBS/n:gIBS/n:gIBSUFTot/n:vIBSUF')))])
    f.grade([('Valor Total Apurado - IBS', real(n.t(ib + 'n:totCIBS/n:gIBS/n:vIBSTot'))), ('Alíquota - CBS', '-'),
             ('Alíquota Efetiva - CBS', '-'), ('Valor Total Apurado - CBS', real(n.t(ib + 'n:totCIBS/n:gCBS/n:vCBS')))])

    # valores
    f.linha(f.y)
    f.titulo_secao('VALOR TOTAL DA NFS-e', [('VALOR DA OPERAÇÃO / SERVIÇO', real(d('n:valores/n:vServPrest/n:vServ'))),
                                           ('Desconto Incondicionado', real(d('n:valores/n:vDescCondIncond/n:vDescIncond'))),
                                           ('Desconto Condicionado', real(d('n:valores/n:vDescCondIncond/n:vDescCond')))])
    ibscbs = sum(float(n.t(ib + c) or 0) for c in ('n:totCIBS/n:gIBS/n:vIBSTot', 'n:totCIBS/n:gCBS/n:vCBS'))
    f.grade([('Total das Retenções (ISSQN / Federais)', real(n.t('n:valores/n:vTotalRet'))),
             ('VALOR LÍQUIDO DA NFS-e', real(n.t('n:valores/n:vLiq'))), ('Total do IBS/CBS', real(ibscbs)),
             ('VALOR LÍQUIDO DA NFS-e + IBS/CBS', real(n.t(ib + 'n:totCIBS/n:vTotNF') or 0))])

    # informações complementares
    f.linha(f.y)
    pt = 'n:valores/n:trib/n:totTrib/n:pTotTrib/'
    compl = []
    if d(pt + 'n:pTotTribFed') is not None:
        compl.append(f'Totais aproximados dos Tributos cfe. Lei n° 12.741/2012: Federais: {pct(d(pt + "n:pTotTribFed"))}; '
                     f'Estaduais: {pct(d(pt + "n:pTotTribEst"))}; Municipais: {pct(d(pt + "n:pTotTribMun"))};')
    if d('n:serv/n:infoCompl/n:xInfComp'):
        compl.append(d('n:serv/n:infoCompl/n:xInfComp'))
    f.texto(L + 2, f.y + 1.5, 'INFORMAÇÕES COMPLEMENTARES', 7.5, True)
    f.y += 11
    f.corrido('', '\n'.join(compl) or '-', linhas=len(compl) + 1)

    # rodapé
    p.draw_rect(pymupdf.Rect(L, 790, R, 822), color=(0, 0, 0), width=0.6)
    f.y = 790
    f.grade([('DATA CIENTIFICAÇÃO:', ''), ('IDENTIFICAÇÃO E ASSINATURA', ''),
             ('*Nº NFS-e / CHAVE NFS-e', f'{n.t("n:nNFSe")} / {n.chave}')])
    f.texto(L, 826, f'Documento auxiliar gerado pelo NIOGEN a partir do XML oficial da NFS-e (chave {n.chave}), '
                    f'assinado pela Sefin Nacional. Confira em www.nfse.gov.br/ConsultaPublica.', 5.5, largura=R - L)

    f.doc.set_metadata({'title': f'DANFSe {n.chave}', 'author': 'DHARMA TELECOM LTDA', 'creator': 'NIOGEN'})
    saida = f.doc.tobytes(deflate=True, garbage=3)
    f.doc.close()
    return saida, n


def main():
    ap = argparse.ArgumentParser(description='Gera o DANFSe (PDF) a partir do XML da NFS-e.')
    ap.add_argument('--xml', required=True)
    ap.add_argument('--saida', required=True)
    a = ap.parse_args()
    pdf, n = gerar_pdf(pathlib.Path(a.xml).read_bytes())
    arq = pathlib.Path(a.saida) / f'DANFSe_{n.chave}.pdf'
    arq.write_bytes(pdf)
    print(json.dumps({'ok': True, 'pdf': str(arq), 'bytes': len(pdf), 'nNFSe': n.t('n:nNFSe')}, ensure_ascii=False, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
