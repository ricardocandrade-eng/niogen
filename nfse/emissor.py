# NIOGEN | nfse/emissor.py | 23/11/2026 — Claude Code (Opus 5.5)
# Emissão da NFS-e da comissão da Nio pelo Sistema Nacional NFS-e (Sefin Nacional), pedido do Ricardo em 23/11/2026:
# "Vamos fazer a parte api da emissão da nota fiscal por enquanto".
#
# Fontes (lidas antes de escrever — regra 21):
#   · Manual dos Contribuintes — Guia das APIs do Emissor Público Nacional (gov.br/nfse): POST /nfse (geração síncrona),
#     GET /nfse/{chaveAcesso}, GET|HEAD /dps/{id}; o certificado da conexão identifica o ator.
#   · Esquemas XSD v1.01 (nfse-esquemas_xsd-v1-01-20260209, copiados em nfse/xsd/1.01-20260209; o da produção restrita de 20/10/2026 em nfse/xsd/1.01-20261020) — leiaute exato da DPS.
#   · Anexo I v1.01 (RN_RECEPCAO_DPS e RN DPS_NFS-e): mTLS com e-CNPJ ICP-Brasil (E1200–E1209); XML em UTF-8, gzip + base64,
#     SEM prefixo de namespace (E1228); DPS assinada com o certificado do emitente (E0714–E0718); série 00001–49999 =
#     "aplicativo próprio" (E0010 — o Emissor Web usa 70000–79999, por isso a NF nº 1 saiu na série 70000); série + número +
#     município + CNPJ não se repetem (E0014); prestador emitente NÃO informa xNome (E0121) nem precisa do endereço.
#   · Não estava escrito nas fontes oficiais lidas (conferir na 1ª rodada na produção restrita): o nome do campo do corpo
#     JSON (dpsXmlGZipB64, como as bibliotecas usam) e o algoritmo da assinatura (padrão DF-e: RSA-SHA1 + C14N 2001;
#     RSA-SHA256 fica como opção --assinatura sha256).
#
# Segurança (CLAUDE.md, regra 5): o certificado A1 (.pfx) e a senha NUNCA entram no repo, no Drive, no chat ou em log.
# Vêm de variáveis de ambiente: NFSE_PFX (caminho do arquivo) e NFSE_PFX_SENHA. Os dados fixos do prestador, do tomador e do
# serviço ficam num JSON fora do repo (NFSE_CONFIG, padrão ~/.niogen/nfse_config.json), porque este repositório é público.
#
# Emitir NF é irreversível (só se cancela com evento). Por isso:
#   · "montar" só gera e valida o XML (nada sai da máquina);
#   · "enviar" exige --confirmo e, antes de mandar, pergunta à Sefin (HEAD /dps/{id}) se aquela DPS já virou nota —
#     se já virou, NÃO reenvia (evita NF em dobro depois de um envio que caiu no meio);
#   · produção só com --ambiente producao escrito por extenso.
import argparse
import base64
import datetime as dt
import gzip
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile

from lxml import etree

NS = 'http://www.sped.fazenda.gov.br/nfse'
DS = 'http://www.w3.org/2000/09/xmldsig#'
VERSAO = '1.01'
VER_APLIC = 'NIOGEN-1.0'
# Dois leiautes da mesma versão 1.01 (o atributo versao continua "1.01"):
#   · 20260209 — "Documentação atual" (produção) em 23/11/2026;
#   · 20261020 — "Produção restrita" desde 20/10/2026 (NT 009, Reforma Tributária): finNFSe obrigatório no infDPS
#     (depois de tpEmit/cMotivoEmisTI) e xDescServ como último campo do cServ. Achado na 1ª rodada na produção restrita
#     (E1235, 23/11/2026). Quando a produção trocar de leiaute, basta mudar 'leiaute' de AMBIENTES['producao'].
XSD_DIR = pathlib.Path(__file__).parent / 'xsd'
LEIAUTES = ('20260209', '20261020')

AMBIENTES = {
    # tpAmb 2 = homologação (produção restrita); 1 = produção. Bases conforme a página "APIs - Produção Restrita e Produção".
    'restrita': {'tpAmb': '2', 'sefin': 'https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional', 'leiaute': '20261020'},
    'producao': {'tpAmb': '1', 'sefin': 'https://sefin.nfse.gov.br/SefinNacional', 'leiaute': '20260209'},
}

ALG = {
    'sha1': ('http://www.w3.org/2000/09/xmldsig#rsa-sha1', 'http://www.w3.org/2000/09/xmldsig#sha1', hashlib.sha1),
    'sha256': ('http://www.w3.org/2001/04/xmldsig-more#rsa-sha256', 'http://www.w3.org/2001/04/xmlenc#sha256', hashlib.sha256),
}
C14N = 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315'
ENVELOPED = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature'

SP = dt.timezone(dt.timedelta(hours=-3))   # Brasília (sem horário de verão desde 2019)


class ErroNFSe(Exception):
    pass


# ───────────────────────── dados ─────────────────────────
def so_digitos(x):
    return re.sub(r'\D', '', str(x or ''))


def dinheiro(v):
    v = round(float(v), 2)
    if v <= 0:
        raise ErroNFSe('O valor do serviço tem de ser maior que zero.')
    return f'{v:.2f}'


def pct(v):
    return f'{round(float(v), 2):.2f}'


def id_dps(c_loc_emi, cnpj, serie, numero):
    """ "DPS" + município (7) + tipo de inscrição (1: CPF, 2: CNPJ) + inscrição (14) + série (5) + número (15) — Anexo I, regra 139."""
    i = f'DPS{c_loc_emi}2{cnpj.zfill(14)}{str(serie).zfill(5)}{str(numero).zfill(15)}'
    if not re.fullmatch(r'DPS\d{42}', i):
        raise ErroNFSe(f'Identificador da DPS mal formado: {i}')
    return i


def carregar_config(caminho=None):
    p = pathlib.Path(caminho or os.environ.get('NFSE_CONFIG') or pathlib.Path.home() / '.niogen' / 'nfse_config.json')
    if not p.exists():
        raise ErroNFSe(f'Config da NFS-e não encontrada em {p}. Ela fica fora do repo (dados do prestador, do tomador e do serviço).')
    return json.loads(p.read_text(encoding='utf-8'))


def descricao_pedido(itens):
    """Padrão da Nio (mensagem "Comissionamento por PDV"): CAIXA ALTA, dois pontos, sem traço nem ponto, uma linha por item."""
    linhas = [f'PEDIDO DE COMPRA: {so_digitos(p)} ITEM: {so_digitos(i)}' for p, i in itens]
    return '\n'.join(linhas)


# ───────────────────────── a DPS ─────────────────────────
def montar_dps(cfg, *, ambiente, serie, numero, valor, competencia, itens, emissao=None, leiaute=None):
    """Monta a DPS (sem assinatura) na ordem exata do XSD v1.01. cfg = JSON de config; itens = [(pedido, item), …]."""
    amb = AMBIENTES[ambiente]
    leiaute = leiaute or amb['leiaute']
    if leiaute not in LEIAUTES:
        raise ErroNFSe(f'Leiaute desconhecido: {leiaute}')
    novo = leiaute >= '20261020'
    prest, toma, serv = cfg['prestador'], cfg['tomador'], cfg['servico']
    cnpj = so_digitos(prest['cnpj'])
    if len(cnpj) != 14:
        raise ErroNFSe('CNPJ do prestador inválido na config.')
    serie = str(int(serie))
    if not 1 <= int(serie) <= 49999:
        raise ErroNFSe('Série de aplicativo próprio vai de 1 a 49999 (Anexo I, E0010). 70000+ é do Emissor Web.')
    numero = str(int(numero))
    agora = (emissao or dt.datetime.now(SP)).astimezone(SP).replace(microsecond=0)
    # E0008: dhEmi não pode passar da hora do processamento — 1 minuto de folga contra relógio adiantado
    agora = agora - dt.timedelta(minutes=1)
    comp = dt.date.fromisoformat(str(competencia))
    if comp > agora.date():
        raise ErroNFSe('A competência não pode ser depois da emissão (E0015).')
    c_loc = so_digitos(prest['cod_municipio'])

    E = lambda tag, pai=None, texto=None: _el(tag, pai, texto)
    dps = etree.Element(f'{{{NS}}}DPS', nsmap={None: NS})
    dps.set('versao', VERSAO)
    inf = E('infDPS', dps)
    inf.set('Id', id_dps(c_loc, cnpj, serie, numero))
    E('tpAmb', inf, amb['tpAmb'])
    E('dhEmi', inf, agora.isoformat())
    E('verAplic', inf, VER_APLIC)
    E('serie', inf, serie)
    E('nDPS', inf, numero)
    E('dCompet', inf, comp.isoformat())
    E('tpEmit', inf, '1')                    # 1 = prestador
    if novo:
        E('finNFSe', inf, '0')               # 0 = NFS-e regular (único valor do leiaute)
    E('cLocEmi', inf, c_loc)

    p = E('prest', inf)
    E('CNPJ', p, cnpj)
    if prest.get('im'):
        E('IM', p, str(prest['im']))
    # xNome e end do prestador não vão (E0121: o prestador emitente não informa o nome)
    if prest.get('fone'):
        E('fone', p, so_digitos(prest['fone']))
    if prest.get('email'):
        E('email', p, prest['email'])
    rt = E('regTrib', p)
    E('opSimpNac', rt, str(prest.get('op_simples_nacional', 1)))   # 1 = não optante (como na NF nº 1)
    if str(prest.get('op_simples_nacional', 1)) == '3' and prest.get('reg_apuracao_sn'):
        E('regApTribSN', rt, str(prest['reg_apuracao_sn']))
    E('regEspTrib', rt, str(prest.get('reg_esp_trib', 0)))

    t = E('toma', inf)
    E('CNPJ', t, so_digitos(toma['cnpj']))
    if toma.get('im'):
        E('IM', t, str(toma['im']))
    E('xNome', t, toma['nome'])
    end = E('end', t)
    en = E('endNac', end)
    E('cMun', en, so_digitos(toma['cod_municipio']))
    E('CEP', en, so_digitos(toma['cep']))
    E('xLgr', end, toma['logradouro'])
    E('nro', end, str(toma['numero']))
    if toma.get('complemento'):
        E('xCpl', end, toma['complemento'])
    E('xBairro', end, toma['bairro'])
    if toma.get('email'):
        E('email', t, toma['email'])

    s = E('serv', inf)
    lp = E('locPrest', s)
    E('cLocPrestacao', lp, so_digitos(serv.get('cod_municipio_prestacao') or c_loc))
    cs = E('cServ', s)
    E('cTribNac', cs, so_digitos(serv['cod_trib_nacional']))
    if serv.get('cod_trib_municipal'):
        E('cTribMun', cs, so_digitos(serv['cod_trib_municipal']).zfill(3))
    if not novo:
        E('xDescServ', cs, descricao_pedido(itens))
    if serv.get('cod_nbs'):
        E('cNBS', cs, so_digitos(serv['cod_nbs']))
    if novo:
        E('xDescServ', cs, descricao_pedido(itens))   # no leiaute de 20/10/2026 é o último do cServ

    v = E('valores', inf)
    vsp = E('vServPrest', v)
    E('vServ', vsp, dinheiro(valor))
    tr = E('trib', v)
    tm = E('tribMun', tr)
    E('tribISSQN', tm, '1')                                   # operação tributável
    E('tpRetISSQN', tm, '2' if serv.get('iss_retido') else '1')
    # pAliq não vai: o município de incidência parametriza a alíquota (na NF nº 1 a Sefin aplicou 5 %)
    tt = E('totTrib', tr)
    tot = serv.get('tributos_aprox_pct')
    if tot:
        pt = E('pTotTrib', tt)
        E('pTotTribFed', pt, pct(tot['federal']))
        E('pTotTribEst', pt, pct(tot['estadual']))
        E('pTotTribMun', pt, pct(tot['municipal']))
    else:
        E('indTotTrib', tt, '0')
    return dps


def _el(tag, pai, texto):
    e = etree.SubElement(pai, f'{{{NS}}}{tag}') if pai is not None else etree.Element(f'{{{NS}}}{tag}', nsmap={None: NS})
    if texto is not None:
        texto = str(texto)
        if texto == '':
            raise ErroNFSe(f'Campo {tag} vazio.')
        e.text = texto
    return e


_ESQUEMAS = {}


def _esquema(leiaute):
    """XSD oficial v1.01 (sem rede). Alguns padrões do XSD da Receita vêm como '^…$' (ex.: TSSerieDPS); em XSD, ^ e $ são
    caracteres literais e nenhum valor passaria. A Sefin os trata como âncoras — aqui, numa cópia temporária, eles são tirados
    (o arquivo oficial em nfse/xsd fica intacto)."""
    if leiaute not in _ESQUEMAS:
        base = XSD_DIR / f'{VERSAO}-{leiaute}'
        tmp = pathlib.Path(tempfile.mkdtemp(prefix='nfse_xsd_'))
        for f in base.glob('*.xsd'):
            t = f.read_text(encoding='utf-8')
            t = re.sub(r'(<xs:pattern value=")\^([^"]*?)\$(")', r'\1\2\3', t)
            (tmp / f.name).write_text(t, encoding='utf-8')
        parser = etree.XMLParser(load_dtd=False, no_network=True, resolve_entities=True)
        _ESQUEMAS[leiaute] = etree.XMLSchema(etree.parse(str(tmp / f'DPS_v{VERSAO}.xsd'), parser))
    return _ESQUEMAS[leiaute]


def validar(dps, leiaute):
    """Valida contra o XSD oficial v1.01 do leiaute (20260209 ou 20261020)."""
    esquema = _esquema(leiaute)
    if not esquema.validate(dps):
        raise ErroNFSe('DPS fora do esquema: ' + '; '.join(f'{e.line}: {e.message}' for e in list(esquema.error_log)[:5]))


# ───────────────────────── certificado e assinatura ─────────────────────────
def carregar_pfx(caminho=None, senha=None):
    from cryptography.hazmat.primitives.serialization import pkcs12
    caminho = caminho or os.environ.get('NFSE_PFX')
    senha = senha if senha is not None else os.environ.get('NFSE_PFX_SENHA')
    if not caminho or not pathlib.Path(caminho).exists():
        raise ErroNFSe('Certificado A1 não encontrado: defina NFSE_PFX com o caminho do .pfx (fora do repo e do Drive).')
    if senha is None:
        raise ErroNFSe('Defina NFSE_PFX_SENHA (a senha não vai em arquivo, chat nem log).')
    chave, cert, cadeia = pkcs12.load_key_and_certificates(pathlib.Path(caminho).read_bytes(), senha.encode())
    if chave is None or cert is None:
        raise ErroNFSe('O .pfx não tem chave privada e certificado.')
    return chave, cert, cadeia or []


def cnpj_do_certificado(cert):
    """e-CNPJ ICP-Brasil: CNPJ no OtherName OID 2.16.76.1.3.3 (Anexo I, E1209); na falta, no CN 'RAZAO:CNPJ'."""
    from cryptography import x509
    try:
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        for o in san.get_values_for_type(x509.OtherName):
            if o.type_id.dotted_string == '2.16.76.1.3.3':
                d = so_digitos(o.value.decode('latin-1', 'ignore'))
                if len(d) >= 14:
                    return d[-14:]
    except x509.ExtensionNotFound:
        pass
    cn = ','.join(a.value for a in cert.subject if a.oid.dotted_string == '2.5.4.3')
    m = re.search(r'(\d{14})', cn)
    return m.group(1) if m else None


def _c14n(el):
    """C14N 2001 (inclusiva) de um elemento do documento. NÃO usar etree.tostring(el, method='c14n') direto num elemento
    interno: no lxml 6.1 ele põe xmlns="" em netos quando há namespace padrão aninhado (DPS → Signature) e a assinatura sai
    sobre bytes errados (achado em 23/11/2026, conferindo com a signxml). Reparsear o pedaço isolado dá o resultado certo."""
    return etree.tostring(etree.fromstring(etree.tostring(el)), method='c14n')


def assinar(dps, chave, cert, alg='sha1'):
    """XMLDSig envelopada: Reference ao infDPS (#Id), C14N 2001, Signature filha de DPS logo depois do infDPS,
    no namespace xmldsig SEM prefixo (E1228)."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    alg_sig, alg_dig, h = ALG[alg]
    inf = dps.find(f'{{{NS}}}infDPS')
    ref_id = inf.get('Id')
    digest = base64.b64encode(h(_c14n(inf)).digest()).decode()

    sig = etree.SubElement(dps, f'{{{DS}}}Signature', nsmap={None: DS})
    si = etree.SubElement(sig, f'{{{DS}}}SignedInfo')
    etree.SubElement(si, f'{{{DS}}}CanonicalizationMethod', Algorithm=C14N)
    etree.SubElement(si, f'{{{DS}}}SignatureMethod', Algorithm=alg_sig)
    ref = etree.SubElement(si, f'{{{DS}}}Reference', URI=f'#{ref_id}')
    trs = etree.SubElement(ref, f'{{{DS}}}Transforms')
    etree.SubElement(trs, f'{{{DS}}}Transform', Algorithm=ENVELOPED)
    etree.SubElement(trs, f'{{{DS}}}Transform', Algorithm=C14N)
    etree.SubElement(ref, f'{{{DS}}}DigestMethod', Algorithm=alg_dig)
    etree.SubElement(ref, f'{{{DS}}}DigestValue').text = digest
    hash_alg = hashes.SHA1() if alg == 'sha1' else hashes.SHA256()
    valor = chave.sign(_c14n(si), padding.PKCS1v15(), hash_alg)
    etree.SubElement(sig, f'{{{DS}}}SignatureValue').text = base64.b64encode(valor).decode()
    ki = etree.SubElement(sig, f'{{{DS}}}KeyInfo')
    xd = etree.SubElement(ki, f'{{{DS}}}X509Data')
    etree.SubElement(xd, f'{{{DS}}}X509Certificate').text = base64.b64encode(cert.public_bytes(serialization.Encoding.DER)).decode()
    return dps


def conferir_assinatura(xml_bytes):
    """Confere a assinatura do próprio XML (digest do infDPS e SignatureValue com a chave pública do X509Certificate)."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding
    doc = etree.fromstring(xml_bytes)
    inf = doc.find(f'{{{NS}}}infDPS')
    sig = doc.find(f'{{{DS}}}Signature')
    si = sig.find(f'{{{DS}}}SignedInfo')
    alg_sig = si.find(f'{{{DS}}}SignatureMethod').get('Algorithm')
    alg = 'sha1' if alg_sig.endswith('rsa-sha1') else 'sha256'
    h = ALG[alg][2]
    if base64.b64encode(h(_c14n(inf)).digest()).decode() != si.find(f'.//{{{DS}}}DigestValue').text:
        raise ErroNFSe('Digest do infDPS não confere.')
    cert = x509.load_der_x509_certificate(base64.b64decode(sig.find(f'.//{{{DS}}}X509Certificate').text))
    cert.public_key().verify(base64.b64decode(sig.find(f'{{{DS}}}SignatureValue').text), _c14n(si),
                             padding.PKCS1v15(), hashes.SHA1() if alg == 'sha1' else hashes.SHA256())
    return True


def serializar(dps):
    xml = etree.tostring(dps, xml_declaration=True, encoding='UTF-8')
    if b' xmlns:' in xml:
        raise ErroNFSe('Prefixo de namespace no XML (E1228).')
    return xml


# ───────────────────────── a Sefin Nacional ─────────────────────────
class Sefin:
    """Cliente com TLS mútuo (o certificado A1 da conexão identifica o prestador)."""

    def __init__(self, ambiente, chave, cert, cadeia=(), timeout=60):
        import requests
        from cryptography.hazmat.primitives import serialization
        self.base = AMBIENTES[ambiente]['sefin']
        self._dir = tempfile.TemporaryDirectory(prefix='nfse_')
        pem = pathlib.Path(self._dir.name) / 'cliente.pem'
        # PEM temporário só durante a sessão (o requests não aceita a chave em memória); apagado no fim
        pem.write_bytes(chave.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                                            serialization.NoEncryption())
                        + cert.public_bytes(serialization.Encoding.PEM)
                        + b''.join(c.public_bytes(serialization.Encoding.PEM) for c in cadeia))
        os.chmod(pem, 0o600)
        self.s = requests.Session()
        self.s.cert = str(pem)
        self.s.headers.update({'Accept': 'application/json'})
        self.timeout = timeout

    def fechar(self):
        self.s.close()
        self._dir.cleanup()

    def dps_existe(self, id_):
        """HEAD /dps/{id}: a DPS já virou NFS-e? (200 = sim, 404 = não)."""
        r = self.s.head(f'{self.base}/dps/{id_}', timeout=self.timeout)
        if r.status_code == 200:
            return True
        if r.status_code == 404:
            return False
        raise ErroNFSe(f'HEAD /dps respondeu {r.status_code}')

    def chave_da_dps(self, id_):
        r = self.s.get(f'{self.base}/dps/{id_}', timeout=self.timeout)
        return r.status_code, _json(r)

    def enviar(self, xml_assinado):
        corpo = {'dpsXmlGZipB64': base64.b64encode(gzip.compress(xml_assinado)).decode()}
        r = self.s.post(f'{self.base}/nfse', json=corpo, timeout=self.timeout)
        return r.status_code, _json(r)

    def consultar(self, chave):
        r = self.s.get(f'{self.base}/nfse/{chave}', timeout=self.timeout)
        return r.status_code, _json(r)


def _json(r):
    try:
        return r.json()
    except ValueError:
        return {'texto': r.text[:2000]}


def xml_da_resposta(campo_b64):
    return gzip.decompress(base64.b64decode(campo_b64))


# ───────────────────────── linha de comando ─────────────────────────
def main():
    ap = argparse.ArgumentParser(description='NFS-e Nacional da comissão da Nio (NIOGEN). Nada é enviado sem "enviar --confirmo".')
    sub = ap.add_subparsers(dest='cmd', required=True)

    def comuns(p):
        p.add_argument('--ambiente', choices=list(AMBIENTES), default='restrita')
        p.add_argument('--serie', default='1')
        p.add_argument('--numero', required=True, help='nº da DPS nesta série (não repete — E0014)')
        p.add_argument('--valor', required=True)
        p.add_argument('--competencia', required=True, help='AAAA-MM-DD')
        p.add_argument('--pedido', action='append', required=True, help='pedido de compra da Nio (repita para mais de um)')
        p.add_argument('--item', action='append', help='item de cada pedido (padrão 10)')
        p.add_argument('--config')
        p.add_argument('--assinatura', choices=list(ALG), default='sha1')
        p.add_argument('--leiaute', choices=LEIAUTES, help='padrão: o do ambiente (restrita 20261020, producao 20260209)')
        p.add_argument('--saida', help='pasta para gravar o XML (fora do repo)')

    comuns(sub.add_parser('montar', help='gera, valida e assina o XML (nada sai da máquina)'))
    e = sub.add_parser('enviar', help='envia a DPS à Sefin Nacional (irreversível em produção)')
    comuns(e)
    e.add_argument('--confirmo', action='store_true', help='obrigatório: confirma que quer gerar a NFS-e')
    c = sub.add_parser('consultar', help='consulta uma NFS-e pela chave de acesso')
    c.add_argument('--ambiente', choices=list(AMBIENTES), default='restrita')
    c.add_argument('--chave', required=True)
    c.add_argument('--saida')
    sub.add_parser('certificado', help='mostra titular, CNPJ e validade do certificado A1 (sem a chave)')
    a = ap.parse_args()

    try:
        if a.cmd == 'certificado':
            _, cert, _ = carregar_pfx()
            print(json.dumps({'titular': cert.subject.rfc4514_string(), 'cnpj': cnpj_do_certificado(cert),
                              'valido_de': cert.not_valid_before_utc.isoformat(), 'valido_ate': cert.not_valid_after_utc.isoformat()},
                             ensure_ascii=False, indent=1))
            return 0
        if a.cmd == 'consultar':
            chave, cert, cadeia = carregar_pfx()
            sf = Sefin(a.ambiente, chave, cert, cadeia)
            try:
                st, j = sf.consultar(a.chave)
            finally:
                sf.fechar()
            if st == 200 and a.saida and j.get('nfseXmlGZipB64'):
                (pathlib.Path(a.saida) / f'NFSe_{a.chave}.xml').write_bytes(xml_da_resposta(j['nfseXmlGZipB64']))
            print(json.dumps({'status': st, 'resposta': {k: v for k, v in j.items() if k != 'nfseXmlGZipB64'}}, ensure_ascii=False, indent=1))
            return 0 if st == 200 else 1

        cfg = carregar_config(a.config)
        itens = list(zip(a.pedido, (a.item or []) + ['10'] * (len(a.pedido) - len(a.item or []))))
        leiaute = a.leiaute or AMBIENTES[a.ambiente]['leiaute']
        dps = montar_dps(cfg, ambiente=a.ambiente, serie=a.serie, numero=a.numero, valor=a.valor, competencia=a.competencia,
                         itens=itens, leiaute=leiaute)
        validar(dps, leiaute)
        chave, cert, cadeia = carregar_pfx()
        cn = cnpj_do_certificado(cert)
        if cn and cn != so_digitos(cfg['prestador']['cnpj']):
            raise ErroNFSe('O certificado não é do prestador da config (E0718: a DPS é assinada pelo emitente).')
        assinar(dps, chave, cert, a.assinatura)
        validar(dps, leiaute)
        xml = serializar(dps)
        conferir_assinatura(xml)
        id_ = dps.find(f'{{{NS}}}infDPS').get('Id')
        if a.saida:
            (pathlib.Path(a.saida) / f'{id_}.xml').write_bytes(xml)
        if a.cmd == 'montar':
            print(json.dumps({'ok': True, 'id': id_, 'ambiente': a.ambiente, 'bytes': len(xml), 'assinatura': a.assinatura,
                              'xsd': f'válido (leiaute {leiaute})', 'saida': a.saida}, ensure_ascii=False, indent=1))
            return 0

        if not a.confirmo:
            raise ErroNFSe('Envio recusado: falta --confirmo. Emitir NF é irreversível.')
        sf = Sefin(a.ambiente, chave, cert, cadeia)
        try:
            if sf.dps_existe(id_):
                st, j = sf.chave_da_dps(id_)
                print(json.dumps({'ja_emitida': True, 'id': id_, 'status': st, 'resposta': j}, ensure_ascii=False, indent=1))
                return 2
            st, j = sf.enviar(xml)
        finally:
            sf.fechar()
        if st in (200, 201) and j.get('chaveAcesso'):
            if a.saida and j.get('nfseXmlGZipB64'):
                (pathlib.Path(a.saida) / f'NFSe_{j["chaveAcesso"]}.xml').write_bytes(xml_da_resposta(j['nfseXmlGZipB64']))
            print(json.dumps({'emitida': True, 'id': id_, 'status': st, 'chaveAcesso': j['chaveAcesso'],
                              'resposta': {k: v for k, v in j.items() if k != 'nfseXmlGZipB64'}}, ensure_ascii=False, indent=1))
            return 0
        print(json.dumps({'emitida': False, 'id': id_, 'status': st, 'resposta': j}, ensure_ascii=False, indent=1))
        return 1
    except ErroNFSe as e:
        print(json.dumps({'erro': str(e)}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    sys.exit(main())
