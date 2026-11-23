# NIOGEN | tests/nfse_emissor_test.py | 23/11/2026 — Claude Code (Opus 5.5)
# Teste local do emissor da NFS-e (nfse/emissor.py), sem rede e sem o certificado real: dados FICTÍCIOS e um certificado
# autoassinado gerado na hora. Prova: leiaute contra o XSD oficial v1.01, Id da DPS, regras do Anexo I que dá para checar
# aqui (série de aplicativo próprio, sem xNome do prestador, sem prefixo de namespace), assinatura conferível e que qualquer
# mudança depois de assinar quebra a assinatura.
# Rodar: python tests/nfse_emissor_test.py
import base64
import datetime as dt
import gzip
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'nfse'))
import emissor as E  # noqa: E402
from cryptography import x509  # noqa: E402
from cryptography.hazmat.primitives import hashes  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: E402
from cryptography.x509.oid import NameOID  # noqa: E402
from lxml import etree  # noqa: E402

CFG = {  # fictício
    'prestador': {'cnpj': '11.222.333/0001-81', 'cod_municipio': '3136702', 'fone': '(32) 99999-0000', 'email': 'teste@exemplo.com',
                  'op_simples_nacional': 1, 'reg_esp_trib': 0},
    'tomador': {'cnpj': '44.555.666/0001-77', 'nome': 'TOMADOR DE TESTE S.A.', 'cod_municipio': '2704302', 'cep': '57.000-000',
                'logradouro': 'RUA DE TESTE', 'numero': '100', 'complemento': 'SALA 1', 'bairro': 'CENTRO'},
    'servico': {'cod_trib_nacional': '10.01.01', 'cod_trib_municipal': '002',
                'tributos_aprox_pct': {'federal': 1, 'estadual': 1, 'municipal': 1}},
}
falhas = []


def confere(nome, cond, det=''):
    print(('ok   ' if cond else 'FALHA') + ' ' + nome + (f' — {det}' if det and not cond else ''))
    if not cond:
        falhas.append(nome)


def recusa(nome, f, trecho):
    try:
        f()
        confere(nome, False, 'não recusou')
    except E.ErroNFSe as e:
        confere(nome, trecho in str(e), str(e))


def cert_teste(cnpj='11222333000181'):
    k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    nome = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f'EMPRESA TESTE:{cnpj}')])
    agora = dt.datetime.now(dt.timezone.utc)
    c = (x509.CertificateBuilder().subject_name(nome).issuer_name(nome).public_key(k.public_key())
         .serial_number(x509.random_serial_number()).not_valid_before(agora - dt.timedelta(days=1))
         .not_valid_after(agora + dt.timedelta(days=30)).sign(k, hashes.SHA256()))
    return k, c


emissao = dt.datetime(2026, 11, 18, 9, 49, 24, tzinfo=E.SP)
dps = E.montar_dps(CFG, ambiente='restrita', serie='1', numero='1', valor='380', competencia='2026-11-18',
                   itens=[('4500156375', '10')], emissao=emissao + dt.timedelta(minutes=5))
E.validar(dps)
confere('DPS sem assinatura passa no XSD oficial v1.01', True)
inf = dps.find(f'{{{E.NS}}}infDPS')
g = lambda caminho: inf.findtext(caminho, namespaces={'n': E.NS})  # noqa: E731
confere('Id = DPS + município + 2 + CNPJ + série(5) + número(15)',
        inf.get('Id') == 'DPS' + '3136702' + '2' + '11222333000181' + '00001' + '000000000000001', inf.get('Id'))
confere('tpAmb 2 na produção restrita', g('n:tpAmb') == '2')
confere('prestador sem xNome e sem endereço (E0121)', inf.find(f'{{{E.NS}}}prest/{{{E.NS}}}xNome') is None
        and inf.find(f'{{{E.NS}}}prest/{{{E.NS}}}end') is None)
confere('descrição no padrão da Nio', g('n:serv/n:cServ/n:xDescServ') == 'PEDIDO DE COMPRA: 4500156375 ITEM: 10')
confere('código de tributação sem pontos (100101) e municipal 002', g('n:serv/n:cServ/n:cTribNac') == '100101'
        and g('n:serv/n:cServ/n:cTribMun') == '002')
confere('valor 380.00, ISS não retido, sem pAliq', g('n:valores/n:vServPrest/n:vServ') == '380.00'
        and g('n:valores/n:trib/n:tribMun/n:tpRetISSQN') == '1' and g('n:valores/n:trib/n:tribMun/n:pAliq') is None)
confere('dhEmi com fuso -03:00 e 1 min antes', g('n:dhEmi') == '2026-11-18T09:53:24-03:00', g('n:dhEmi'))

dois = E.montar_dps(CFG, ambiente='restrita', serie='1', numero='2', valor='430', competencia='2026-11-18',
                    itens=[('4500000001', '10'), ('4500000002', '20')], emissao=emissao)
confere('dois pedidos = uma linha por item', dois.findtext(f'.//{{{E.NS}}}xDescServ') ==
        'PEDIDO DE COMPRA: 4500000001 ITEM: 10\nPEDIDO DE COMPRA: 4500000002 ITEM: 20')

recusa('série do Emissor Web (70000) é recusada', lambda: E.montar_dps(CFG, ambiente='restrita', serie='70000', numero='1', valor='1',
       competencia='2026-11-18', itens=[('1', '10')], emissao=emissao), 'Série')
recusa('competência depois da emissão é recusada', lambda: E.montar_dps(CFG, ambiente='restrita', serie='1', numero='1', valor='1',
       competencia='2026-12-01', itens=[('1', '10')], emissao=emissao), 'competência')
recusa('valor zero é recusado', lambda: E.montar_dps(CFG, ambiente='restrita', serie='1', numero='1', valor='0',
       competencia='2026-11-18', itens=[('1', '10')], emissao=emissao), 'maior que zero')

k, c = cert_teste()
confere('CNPJ lido do certificado (CN)', E.cnpj_do_certificado(c) == '11222333000181')
for alg in ('sha1', 'sha256'):
    d = E.montar_dps(CFG, ambiente='restrita', serie='1', numero='3', valor='380', competencia='2026-11-18',
                     itens=[('4500156375', '10')], emissao=emissao)
    E.assinar(d, k, c, alg)
    E.validar(d)
    xml = E.serializar(d)
    confere(f'[{alg}] DPS assinada passa no XSD', True)
    confere(f'[{alg}] sem prefixo de namespace (E1228)', b'xmlns:' not in xml and b'<ds:' not in xml)
    confere(f'[{alg}] Signature é filha de DPS, depois do infDPS', [etree.QName(x).localname for x in d] == ['infDPS', 'Signature'])
    confere(f'[{alg}] assinatura confere', E.conferir_assinatura(xml))
    # conferência por quem não escreveu a assinatura (pip install signxml): pegou o defeito do C14N do lxml em 23/11
    try:
        from signxml import XMLVerifier, SignatureConfiguration, SignatureMethod, DigestAlgorithm
        cfg = SignatureConfiguration(signature_methods=frozenset(SignatureMethod), digest_algorithms=frozenset(DigestAlgorithm), require_x509=False)
        ok = XMLVerifier().verify(xml, x509_cert=c, expect_config=cfg).signed_xml.get('Id') == d.find(f'{{{E.NS}}}infDPS').get('Id')
        confere(f'[{alg}] signxml (independente) aceita a assinatura do infDPS', ok)
    except ImportError:
        print(f'aviso [{alg}] signxml não instalada: conferência independente pulada')
    except Exception as e:  # noqa: BLE001
        confere(f'[{alg}] signxml (independente) aceita a assinatura do infDPS', False, f'{type(e).__name__}: {e}')
    confere(f'[{alg}] UTF-8 e gzip+base64 ida e volta', gzip.decompress(base64.b64decode(base64.b64encode(gzip.compress(xml)))) == xml
            and xml.startswith(b"<?xml version='1.0' encoding='UTF-8'?>"))
    mexido = xml.replace(b'<vServ>380.00</vServ>', b'<vServ>3800.00</vServ>')
    try:
        E.conferir_assinatura(mexido)
        confere(f'[{alg}] valor mexido depois de assinar é pego', False)
    except Exception:
        confere(f'[{alg}] valor mexido depois de assinar é pego', True)

print(f'\n{"TUDO VERDE" if not falhas else str(len(falhas)) + " FALHA(S): " + ", ".join(falhas)}')
sys.exit(1 if falhas else 0)
