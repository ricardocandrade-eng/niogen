# NIOGEN | nfse/servico.py | 23/11/2026 — Claude Code (Opus 5.5)
# Serviço niogen-nfse (VPS do n8n, /opt/niogen/nfse/): o botão "Emitir NF" da Conciliação chega aqui pela edge function
# nfse-emitir. Ricardo, 23/11: "Um clique" (emite → PDF → e-mail à Nio depois de uma confirmação) e "Teste primeiro".
#
# Rotas (todas exigem Authorization: Bearer NFSE_SERVICO_TOKEN; sem ele, 401):
#   GET  /saude                 → certificado (CNPJ, validade), config e SMTP presentes — sem segredo
#   POST /previa  {ambiente, documento, item, valor, ciclo_nio}            → o que vai sair (tomador, descrição, e-mail)
#   POST /emitir  {ambiente, serie, numero, valor, competencia, documento, item, ciclo_nio}
#                 → monta e assina a DPS, confere se ela já virou nota (HEAD /dps), envia à Sefin, gera o PDF e manda o e-mail
#                   (restrita: só para o remetente, como teste; produção: à Nio, para + cópias da config)
#   POST /email   {ambiente, chave, ciclo_nio}                              → reenvia o e-mail com o PDF guardado
# Uma emissão por vez (trava). XML e PDF ficam em /saida (volume) e voltam em base64 para a edge function guardar no Storage.
#
# Segredos só no .env da VPS e em /segredos (chmod 700, fora do repo e do Drive): NFSE_SERVICO_TOKEN, NFSE_PFX (arquivo),
# NFSE_PFX_SENHA, ZOHO_SMTP_SENHA, NFSE_CONFIG (JSON com prestador, tomador, serviço e e-mail). Nada disso sai nas respostas
# nem no log.
import base64
import datetime as dt
import hmac
import json
import os
import pathlib
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import emissor as E  # noqa: E402
import email_nio as M  # noqa: E402
from danfse import gerar_pdf  # noqa: E402

TOKEN = (os.environ.get('NFSE_SERVICO_TOKEN') or '').strip()
SAIDA = pathlib.Path(os.environ.get('NFSE_SAIDA', '/saida'))
PORTA = int(os.environ.get('NFSE_PORTA', '8092'))
TRAVA = threading.Lock()


def log(**k):
    print(json.dumps({'em': dt.datetime.now(E.SP).isoformat(timespec='seconds'), **k}, ensure_ascii=False), flush=True)


def ciclo_ok(c):
    M.titulo('X', c)   # valida o padrão 1QNOV26 (levanta ErroEmail)
    return c.upper()


def previa(b):
    cfg = E.carregar_config()
    ce = cfg['email_nio']
    amb = b['ambiente']
    itens = [(b['documento'], b.get('item') or '10')]
    para, cc = ([ce['remetente']], []) if amb == 'restrita' else (ce['para'], ce.get('cc') or [])
    return {'ambiente': amb, 'tomador': {'nome': cfg['tomador']['nome'], 'cnpj': E.so_digitos(cfg['tomador']['cnpj'])},
            'servico': {'cod_trib_nacional': cfg['servico']['cod_trib_nacional'], 'cod_trib_municipal': cfg['servico'].get('cod_trib_municipal')},
            'descricao': E.descricao_pedido(itens), 'valor': E.dinheiro(b['valor']),
            'email': {'para': para, 'cc': cc, 'titulo': M.titulo(ce['razao_social'], ciclo_ok(b['ciclo_nio'])),
                      'modo': 'teste (só para o remetente)' if amb == 'restrita' else 'Nio'}}


def mandar_email(cfg, amb, pdf_path, ciclo_nio):
    ce = cfg['email_nio']
    teste = ce['remetente'] if amb == 'restrita' else None
    m = M.montar(ce, pdf_path, ciclo_ok(ciclo_nio), teste=teste)
    recusados = M.enviar(ce, m)
    if recusados:
        raise M.ErroEmail(f'recusados: {recusados}')
    para = m['To'] + (f' (cc {m["Cc"]})' if m['Cc'] else '')
    (SAIDA / f'{pathlib.Path(pdf_path).stem}_{amb}.eml').write_bytes(bytes(m))
    return para


def emitir(b):
    amb = b['ambiente']
    if amb not in E.AMBIENTES:
        raise E.ErroNFSe('ambiente inválido')
    cfg = E.carregar_config()
    itens = [(b['documento'], b.get('item') or '10')]
    leiaute = E.AMBIENTES[amb]['leiaute']
    dps = E.montar_dps(cfg, ambiente=amb, serie=b['serie'], numero=b['numero'], valor=b['valor'], competencia=b['competencia'],
                       itens=itens, leiaute=leiaute)
    E.validar(dps, leiaute)
    chave, cert, cadeia = E.carregar_pfx()
    if E.cnpj_do_certificado(cert) != E.so_digitos(cfg['prestador']['cnpj']):
        raise E.ErroNFSe('O certificado não é do prestador da config.')
    E.assinar(dps, chave, cert, 'sha1')
    E.validar(dps, leiaute)
    xml = E.serializar(dps)
    id_ = dps.find(f'{{{E.NS}}}infDPS').get('Id')
    (SAIDA / f'{id_}.xml').write_bytes(xml)
    out = {'id_dps': id_}
    sf = E.Sefin(amb, chave, cert, cadeia)
    try:
        if sf.dps_existe(id_):
            # a DPS já virou nota (envio anterior que caiu no meio): não reenvia; busca a chave e o XML
            st, j = sf.chave_da_dps(id_)
            ch = j.get('chaveAcesso') if isinstance(j, dict) else None
            if not ch:
                raise E.ErroNFSe(f'A DPS {id_} já virou nota, mas a Sefin não devolveu a chave (status {st}).')
            st2, j2 = sf.consultar(ch)
            j = {'chaveAcesso': ch, 'nfseXmlGZipB64': j2.get('nfseXmlGZipB64')}
            out['ja_existia'] = True
            st = 201
        else:
            st, j = sf.enviar(xml)
    finally:
        sf.fechar()
    if st not in (200, 201) or not j.get('chaveAcesso'):
        erros = j.get('erros') or j.get('erro') or j
        out.update(emitida=False, status=st, erro=json.dumps(erros, ensure_ascii=False)[:1500])
        return out
    xml_nfse = E.xml_da_resposta(j['nfseXmlGZipB64'])
    ch = j['chaveAcesso']
    (SAIDA / f'NFSe_{ch}.xml').write_bytes(xml_nfse)
    pdf, nota = gerar_pdf(xml_nfse)
    pdf_path = SAIDA / f'DANFSe_{ch}.pdf'
    pdf_path.write_bytes(pdf)
    out.update(emitida=True, chave=ch, n_nfse=nota.t('n:nNFSe'), dh_proc=nota.t('n:dhProc'),
               xml_b64=base64.b64encode(xml_nfse).decode(), pdf_b64=base64.b64encode(pdf).decode())
    try:
        out['email'] = {'enviado': True, 'para': mandar_email(cfg, amb, pdf_path, b['ciclo_nio']),
                        'em': dt.datetime.now(E.SP).isoformat(timespec='seconds')}
    except Exception as e:  # noqa: BLE001 — a nota saiu; o e-mail falho vira "Reenviar e-mail"
        out['email'] = {'enviado': False, 'erro': f'{type(e).__name__}: {e}'[:500]}
    return out


def reenviar(b):
    cfg = E.carregar_config()
    pdf_path = SAIDA / f'DANFSe_{E.so_digitos(b["chave"])}.pdf'
    if not pdf_path.exists():
        raise E.ErroNFSe('PDF desta nota não está no serviço.')
    return {'enviado': True, 'para': mandar_email(cfg, b['ambiente'], pdf_path, b['ciclo_nio']),
            'em': dt.datetime.now(E.SP).isoformat(timespec='seconds')}


def saude():
    r = {'ok': True, 'config': False, 'certificado': None, 'smtp': bool(os.environ.get('ZOHO_SMTP_SENHA'))}
    try:
        cfg = E.carregar_config()
        r['config'] = bool(cfg.get('prestador') and cfg.get('tomador') and cfg.get('email_nio', {}).get('remetente'))
        _, cert, _ = E.carregar_pfx()
        r['certificado'] = {'cnpj': E.cnpj_do_certificado(cert), 'valido_ate': cert.not_valid_after_utc.date().isoformat()}
    except Exception as e:  # noqa: BLE001
        r.update(ok=False, erro=str(e)[:300])
    return r


class H(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        corpo = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def _autorizado(self):
        dado = (self.headers.get('Authorization') or '').removeprefix('Bearer ').strip()
        return bool(TOKEN) and hmac.compare_digest(dado, TOKEN)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if not self._autorizado():
            return self._json(401, {'erro': 'não autorizado'})
        if self.path.rstrip('/') == '/saude':
            return self._json(200, saude())
        return self._json(404, {'erro': 'rota'})

    def do_POST(self):
        if not self._autorizado():
            return self._json(401, {'erro': 'não autorizado'})
        try:
            b = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}')
        except ValueError:
            return self._json(400, {'erro': 'json inválido'})
        rota = self.path.rstrip('/')
        t0 = dt.datetime.now()
        try:
            if rota == '/previa':
                return self._json(200, previa(b))
            if rota in ('/emitir', '/email'):
                if not TRAVA.acquire(timeout=90):
                    return self._json(409, {'erro': 'outra emissão em andamento'})
                try:
                    r = emitir(b) if rota == '/emitir' else reenviar(b)
                finally:
                    TRAVA.release()
                log(rota=rota, ambiente=b.get('ambiente'), numero=b.get('numero'), emitida=r.get('emitida'), chave=r.get('chave'),
                    email=(r.get('email') or {}).get('enviado') if rota == '/emitir' else r.get('enviado'),
                    ms=int((dt.datetime.now() - t0).total_seconds() * 1000))
                return self._json(200, r)
            return self._json(404, {'erro': 'rota'})
        except (E.ErroNFSe, M.ErroEmail, KeyError) as e:
            log(rota=rota, erro=str(e)[:300])
            return self._json(422, {'erro': f'{type(e).__name__}: {e}'})
        except Exception as e:  # noqa: BLE001
            log(rota=rota, erro=traceback.format_exc()[-800:])
            return self._json(500, {'erro': f'{type(e).__name__}: {e}'})


if __name__ == '__main__':
    if not TOKEN:
        sys.exit('NFSE_SERVICO_TOKEN não definido')
    SAIDA.mkdir(parents=True, exist_ok=True)
    log(inicio=True, porta=PORTA, saude=saude())
    ThreadingHTTPServer(('0.0.0.0', PORTA), H).serve_forever()
