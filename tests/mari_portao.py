#!/usr/bin/env python3
# NIOGEN | tests/mari_portao.py | 08/11/2026 — Claude Code (Onda 1.2, docs/Prompt_portao_mari_alarme_081126_0100.md, Parte 1)
# Bateria FIXA "portao": todos os cenários do ensaio (a…p da mari_v7_bateria) + os que faltavam para cada falha já
# vista em produção (P1–P15), com checagem automática. É o portão do deploy: o deploy_mari.py só publica no
# mari_principal se existir uma rodada daqui 100 % verde, completa, com o mesmo hash, nas últimas 6 h.
#
# Roda SÓ no ensaio (mari_principal_v3, rota mari-teste-v3, credencial "Claude API Nio — Testes", telefones 5500000003xxx).
# Nunca contra a produção nem com a chave da produção. Antes de gastar API confere que o ensaio está igual ao código
# local (deploy_mari.py conferir --ensaio) — senão a rodada não provaria nada.
# Teto de custo por rodada (padrão US$ 2; --teto N): passou, para, grava a rodada como incompleta e avisa.
# Limpeza (mari_limpar_teste) sempre, também em erro/Ctrl+C. Resultado em mari_portao_rodadas e tests/saida/.
#
# Uso: python tests/mari_portao.py [--teto 2] [--paralelo 4] [--so a,k]   (--so = rodada parcial: NUNCA abre o portão)
#
# Regra (CLAUDE.md do repo, "Regras da Mari"): falha nova achada em teste real → ANTES de corrigir, escrever o cenário
# que a reproduz aqui (vermelho), depois corrigir até ficar verde.
import concurrent.futures as cf
import datetime
import json
import os
import re
import subprocess
import sys
import threading

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
sys.path.insert(0, AQUI)
import mari_v7_bateria as B   # noqa: E402  (Conversa, cenários a…p, sql, falar, custo, norm)

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
norm = B.norm

# Internet instável (08/11 22h48: "Transport error" no meio da rodada deixou a limpeza por fazer): o SQL tenta 3 vezes.
# As escritas daqui são idempotentes (limpeza, fechar ciclo) ou só a última linha da rodada.
_sql_orig = B.sql


def _sql_retry(q, escrita=False):
    import time
    for i in range(3):
        try:
            return _sql_orig(q, escrita)
        except RuntimeError as e:
            if i == 2 or not re.search(r'Transport error|timeout|connection|10054|EOF', str(e), re.I):
                raise
            time.sleep(5 * (i + 1))


B.sql = _sql_retry


def arg(nome, padrao):
    if nome in sys.argv:
        i = sys.argv.index(nome)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return padrao


TETO = float(arg('--teto', '2'))   # prompt: US$ 2. Rodada completa de 08/11 22h26 custou US$ 1,35 (Sonnet, 15 cenários)
PARALELO = max(1, int(arg('--paralelo', '4')))
SO = [x for x in arg('--so', '').split(',') if x]


class TetoExcedido(Exception):
    pass


GASTO = {'usd': 0.0}
LOCK = threading.Lock()


# ───────── preços que existem (P3): config_planos ativos + adicionais + diferenças do mesmo cluster + taxa parcelada ─────────
def precos_permitidos():
    ok = {0.0}
    planos = B.sql("select cluster, preco, preco_cartao, taxa_habilitacao from config_planos where ativo")
    adic = B.sql("select preco from config_adicionais where ativo")
    por_cluster = {}
    for r in planos:
        for k in ('preco', 'preco_cartao', 'taxa_habilitacao'):
            if r.get(k) not in (None, ''):
                v = round(float(r[k]), 2)
                ok.add(v)
                if k != 'taxa_habilitacao':
                    por_cluster.setdefault(r.get('cluster'), set()).add(v)
                else:
                    ok.update(round(v / n, 2) for n in range(2, 13))
    for r in adic:
        if r.get('preco') not in (None, ''):
            ok.add(round(float(r['preco']), 2))
    for vs in por_cluster.values():
        ok.update(round(abs(a - b), 2) for a in vs for b in vs if a != b)
    return ok


PRECOS_OK = set()
RX_PRECO = re.compile(r'R\$\s*(\d{1,3}(?:\.\d{3})*(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)')
RX_MARCA = re.compile(r'\[(?:BOTOES|BOTÕES|HANDOFF|CONDICOES|CONDIÇÕES|PLANOS|CARROSSEL|LISTA|BUSCA|ESTADO|TAG|bot[õo]es)[^\]]*\]', re.I)
RX_COMPARA = re.compile(r'\bdobro\b|duas vezes|\btriplo\b|\bmetade\b|\b\d+\s*x\s+mais\b|\b\d+\s+vezes\s+mais\b')
RX_CPF_RUIM = re.compile(r'cpf[^.?!\n]{0,40}(incomplet|invalid|nao (parece|esta) (certo|correto|valido)|faltando)')


def valor(s):
    s = s.strip()
    if ',' in s:
        s = s.replace('.', '').replace(',', '.')
    return round(float(s), 2)


class ConversaPortao(B.Conversa):
    """Conversa do ensaio + checagens globais do portão em TODA fala da Mari."""

    def __init__(self, cid, n, nome='Teste V7'):
        super().__init__(cid, n, nome)
        self.pos_handoff = False
        self.email_dado = False

    def diz(self, texto):
        with LOCK:
            if GASTO['usd'] > TETO:
                raise TetoExcedido(f'teto de US$ {TETO:.2f} passou (US$ {GASTO["usd"]:.2f}) — rodada parada')
        r = super().diz(texto)
        u = r.get('uso') or {}
        with LOCK:
            GASTO['usd'] += B.custo(u, u.get('modelo') or r.get('modelo')) or 0
        # O que o CLIENTE recebe: os balões + a mensagem interativa. "resposta" é o texto do histórico e guarda a marca
        # "[botões: …]"/"[carrossel: …]" de propósito (contexto do modelo) — checar nele dava P6 falso (rodada de 08/11 22h26).
        it = r.get('interativo') or {}
        bal = r.get('baloes')
        resp = '\n'.join(bal) if isinstance(bal, list) else (r.get('resposta') or '')
        tudo = '\n'.join([resp, it.get('corpo') or '', json.dumps(it.get('itens') or it.get('cards') or '', ensure_ascii=False)])
        n_ = norm(tudo)
        # P5 — toda fala do cliente tem resposta (calada só depois do handoff, que é o silêncio de propósito)
        if not resp.strip() and not it and not r.get('handoff') and not self.pos_handoff:
            self.falha(f'[P5] Mari calada depois de «{texto[:60]}»')
        # P6 — nenhuma marca entre colchetes chega ao cliente
        m = RX_MARCA.search(resp + '\n' + (it.get('corpo') or ''))
        if m:
            self.falha(f'[P6] marca vazou: «{m.group(0)[:60]}»')
        # P3 — nenhum R$ que não exista na tabela
        for x in RX_PRECO.findall(tudo):
            try:
                v = valor(x)
            except ValueError:
                continue
            if v not in PRECOS_OK:
                self.falha(f'[P3] preço fora da tabela: R$ {x}')
        # P8 — sem portal, nunca ✅ nem "atende o seu endereço"
        linhas_ok = [norm(l) for l in tudo.split('\n') if '✅' in l]
        if re.search(r'atende (o )?seu endereco|atende o endereco', n_) or any(re.search(r'atende|cobertura|disponivel', l) for l in linhas_ok):
            self.falha(f'[P8] prometeu cobertura sem portal: «{resp[:100]}»')
        # P10 — nenhuma comparação numérica
        if RX_COMPARA.search(n_):
            self.falha(f'[P10] comparação numérica: «{resp[:120]}»')
        # P12 — CPF válido nunca é reclamado (todos os cenários usam CPF válido)
        if RX_CPF_RUIM.search(n_):
            self.falha(f'[P12] reclamou de CPF válido: «{resp[:120]}»')
        # P16 (portão 08/11 22h40, cenário o) — upsell entre planos de mesma velocidade: "vai de 1 Giga pra 1 Giga"
        m16 = re.search(r'\bde (\d+(?:[.,]\d+)?\s*(?:mega|giga|gb|mb))\s+pra\s+\1\b', n_)
        if m16:
            self.falha(f'[P16] upsell com a mesma velocidade: «{m16.group(0)}»')
        # P17 (portão 08/11 22h48, cenário a) — (1) pagamento perguntado antes de ter o e-mail; (2) o cliente manda o e-mail e
        # a Mari diz que não recebeu / pede de novo.
        if re.search(r'[^\s@]+@[^\s@]+\.[a-z]{2,}', texto, re.I) and re.search(r'e-?mail', n_) \
                and re.search(r'nao recebi|me falta|faltou|pode mandar|me manda|qual (e )?(o )?seu (melhor )?e-?mail', n_):
            self.falha(f'[P17] pediu de novo o e-mail que o cliente acabou de mandar: «{resp[:100]}»')
        if re.search(r'[^\s@]+@[^\s@]+\.[a-z]{2,}', texto, re.I):
            self.email_dado = True
        if it.get('chave') == 'pagamento' and not self.email_dado:
            self.falha('[P17] botões de pagamento antes do e-mail')
        if r.get('handoff'):
            self.pos_handoff = True
        return r

    def fim(self):
        # P11 — no máximo 1 despedida; P14 — "Anotado" no máximo 1×
        txts = [norm((f.get('mari') or '') + ' ' + ((f.get('interativo') or {}).get('corpo') or '')) for f in self.log]
        desp = sum(1 for t in txts if 'confere tudo no sistema da nio' in t)
        if desp > 1:
            self.falha(f'[P11] despedida dados_completos {desp}×')
        # prompt v7, Bloco 3: se a última fala já se despediu ("qualquer coisa é só chamar"), não se despede de novo
        chama = [bool(re.search(r'qualquer coisa (e|eh) so (me )?chamar', t)) for t in txts]
        if any(a and b for a, b in zip(chama, chama[1:])):
            self.falha('[P11] duas despedidas seguidas ("qualquer coisa é só chamar" duas vezes)')
        anot = sum(t.count('anotad') for t in txts)
        if anot > 1:
            self.falha(f'[P14] "Anotado" {anot}×')


def conv_row(c, campos):
    rows = B.sql(f"select {campos} from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    return rows[0] if rows else {}


# ───────── cenários novos / estendidos ─────────
def cen_k_portao(c):   # P1 + P2 (k original) + P4: número e complemento preservados depois da cura
    B.cen_k(c)
    row = conv_row(c, 'cep, cidade, cluster, numero, complemento')
    c.exige(row.get('cidade'), f'[P2] cidade vazia depois da escolha da rua: {row}')
    c.exige(str(row.get('numero') or '') == '123', f'[P4] número perdido: {row.get("numero")!r}')
    c.exige('403' in str(row.get('complemento') or ''), f'[P4] complemento perdido: {row.get("complemento")!r}')
    r = c.diz('Oi')   # o "Oi" que disparou a cura em 07/11 00h26
    row = conv_row(c, 'cep, numero, complemento')
    c.exige(str(row.get('cep') or '').replace('-', '') == '36035130', f'[P2] CEP mudou depois do "Oi": {row.get("cep")!r}')
    c.exige(str(row.get('numero') or '') == '123', f'[P4] número apagado depois do "Oi": {row.get("numero")!r}')
    c.exige('403' in str(row.get('complemento') or ''), f'[P4] complemento apagado depois do "Oi": {row.get("complemento")!r}')
    c.exige(not re.search(r'(planos|opcoes) que (te |eu )?mand', norm(r.get('resposta'))), '[P4] respondeu "dúvida sobre os planos que te mandei"')


def cen_o_portao(c):   # P5 P7 P8 P9 P11 P14 (o original) + P13: retomada responde só a mensagem nova
    B.cen_o(c)
    row = conv_row(c, 'id, status')
    if row.get('status') != 'handoff_realizado':
        c.falha(f'[P13] sem handoff para testar a retomada (status {row.get("status")!r})')
        return
    B.sql(f"select public._mari_fechar_ciclo('{row['id']}'::uuid, 'portao')", escrita=True)   # = "resolvida" no Chatwoot
    r = c.diz('Boa noite!')
    t = norm(r.get('resposta'))
    c.exige((r.get('resposta') or '').strip(), '[P13] calada na retomada')
    c.exige(not re.search(r'\b(imagina|de nada|disponha|por nada)\b', t), f'[P13] respondeu o "Obrigado!" antigo: «{(r.get("resposta") or "")[:120]}»')


def cen_j_portao(c):   # regressão BTU (j original) + P18: pessoa física em cidade BTU recebe a tabela Varejo, nunca a de Empresas
    # Conversa #40 (09/11, Timóteo): mesmos preços BTU nas duas tabelas → a Mari copiou velocidades e inclusos de Empresas.
    B.cen_j(c)
    listas = [x['mari'] for x in c.log if re.search(r'(?m)^\s*1\)', x.get('mari') or '')]
    if not listas:
        return   # o (j) original já reprova sem a lista
    t = norm(listas[-1])
    c.exige(not re.search(r'maquininha|pagbank|mcafee|exame', t), f'[P18] inclusos de Empresas para pessoa física: «{t[:200]}»')
    c.exige(not re.search(r'\b700 mega\b', t), f'[P18] velocidade de Empresas (700 Mega) para pessoa física: «{t[:200]}»')
    c.exige(re.search(r'\b800 mega\b', t) and '1 giga' in t, f'[P18] faltou 800 Mega / 1 Giga da tabela Varejo: «{t[:200]}»')


def cen_p_portao(c):   # P9 P10 (p original) + P19: em JF o upsell Essencial → Super é "por mais R$30" (nunca o R$15 do cartão)
    B.cen_p(c)
    for x in c.log:
        for m in re.finditer(r'por mais r\$\s*(\d+)', norm(x.get('mari'))):
            c.exige(m.group(1) == '30', f'[P19] upsell com a diferença errada (R${m.group(1)}; certo R$30): «{(x.get("mari") or "")[:160]}»')


def cen_q(c):   # P15 — controle: fora do assunto → volta ao fluxo sem inventar
    c.diz('Oi')
    c.diz('Você torce pra qual time? Aqui é Tupi kkkk')
    r = c.diz('Você é muito simpática, Mari!')
    t = norm((r.get('resposta') or '') + ' ' + ((r.get('interativo') or {}).get('corpo') or ''))
    c.exige(not r.get('handoff'), '[P15] encerrou a conversa')
    c.exige(re.search(r'\bcep\b|\brua\b|endereco|bairro', t), f'[P15] não voltou ao fluxo (CEP/rua): «{(r.get("resposta") or "")[:140]}»')
    c.exige(not re.search(r'r\$\s*\d', t), '[P15] falou preço sem CEP')


# cenário → (índice do telefone, função, P# que cobre). Índices iguais aos da mari_v7_bateria; q = 15.
PORTAO = {
    'a': (1, B.cen_a, 'P1 P5 P7 P17'), 'c': (2, B.cen_c, 'P2'), 'd': (3, B.cen_d, 'regressão DFV'), 'e': (4, B.cen_e, 'regressão DFV'),
    'g': (5, B.cen_g, 'regressão já-Nio'), 'h': (6, B.cen_h, 'regressão operadora'), 'i': (7, B.cen_i, 'regressão botão'),
    'j': (8, cen_j_portao, 'regressão BTU + P18'), 'k': (9, cen_k_portao, 'P1 P2 P4'), 'l': (10, B.cen_l, 'P3'),
    'm': (11, B.cen_m, 'regressão rua longa'), 'n': (12, B.cen_n, 'P3'), 'o': (13, cen_o_portao, 'P5 P7 P8 P9 P11 P13 P14 P16'),
    'p': (14, cen_p_portao, 'P9 P10 P19'), 'q': (15, cen_q, 'P15'),
    # 08/11 — abertura B2 (saudação fixa + 3 botões): sem nome, com nome, 1ª mensagem já com CEP, toque em cada botão.
    'r': (16, B.cen_r, 'B2 sem nome'), 's': (17, B.cen_s, 'B2 com nome'), 't': (18, B.cen_t, 'B2 com CEP'), 'u': (19, B.cen_u, 'B2 botões'),
}
GLOBAIS = 'P3 P5 P6 P8 P10 P11 P12 P14 P16 P17 em toda fala'


def rodar(k):
    n, f, _ = PORTAO[k]
    c = ConversaPortao(k, n)
    try:
        f(c)
    except TetoExcedido:
        raise
    except Exception as e:   # noqa: BLE001
        c.falha(f'exceção: {str(e)[:200]}')
    c.fim()
    print(f"({k}) {'VERDE' if not c.falhas else 'VERMELHO'}" + ''.join(f'\n    - {x}' for x in c.falhas), flush=True)
    return c


def hash_producao():
    p = subprocess.run([sys.executable, os.path.join(REPO, 'n8n', 'deploy_mari.py'), 'hash'], capture_output=True, text=True, encoding='utf-8')
    h = p.stdout.strip().splitlines()[-1] if p.returncode == 0 and p.stdout.strip() else ''
    if not re.fullmatch(r'[0-9a-f]{16}', h):
        sys.exit(f'não consegui o hash da produção: {p.stdout[-200:]} {p.stderr[-200:]}')
    return h


def main():
    if not B.SEGREDO:
        sys.exit('MARI_TESTE_SECRET ausente')
    p = subprocess.run([sys.executable, os.path.join(REPO, 'n8n', 'deploy_mari.py'), 'conferir', '--ensaio'],
                       capture_output=True, text=True, encoding='utf-8')
    print(p.stdout.strip())
    if p.returncode != 0:
        sys.exit('ensaio diferente do código local — rode "python n8n/deploy_mari.py codigo --ensaio" (ou estrutura) antes. Nada rodou.')
    h = hash_producao()
    escolha = [k for k in PORTAO if not SO or k in SO]
    parcial = bool(SO)
    PRECOS_OK.update(precos_permitidos())
    print(f'portão · hash {h} · {len(escolha)} cenários{" (PARCIAL — não abre o portão)" if parcial else ""} · teto US$ {TETO:.2f} · '
          f'{PARALELO} em paralelo · checagens globais: {GLOBAIS}', flush=True)
    t0 = datetime.datetime.now()
    res, completa, motivo = {}, False, None
    try:
        B.sql(f"select public.mari_limpar_teste('{B.PREFIXO}')", escrita=True)
        with cf.ThreadPoolExecutor(max_workers=PARALELO) as ex:
            fut = {ex.submit(rodar, k): k for k in escolha}
            for f in cf.as_completed(fut):
                try:
                    res[fut[f]] = f.result()
                except TetoExcedido as e:
                    motivo = str(e)
                    ex.shutdown(wait=False, cancel_futures=True)
                    break
        completa = motivo is None and len(res) == len(escolha) and not parcial
    except KeyboardInterrupt:
        motivo = 'interrompida (Ctrl+C)'
    finally:
        try:
            B.sql(f"select public.mari_limpar_teste('{B.PREFIXO}')", escrita=True)
            print('teardown: mari_limpar_teste ok')
        except Exception as e:   # noqa: BLE001
            print(f'⚠️ teardown falhou: {e}')
        seg = (datetime.datetime.now() - t0).total_seconds()
        verdes = sum(1 for c in res.values() if not c.falhas)
        verm = len(res) - verdes
        modelos = sorted({m for c in res.values() for m in c.totais()['modelos'] if m})
        if parcial:
            motivo = motivo or f'rodada parcial: {",".join(escolha)}'
        detalhe = {'cenarios': {k: {'cobre': PORTAO[k][2], 'falhas': [x[:200] for x in c.falhas], 'falas': len(c.log)}
                                for k, c in sorted(res.items())},
                   'nao_rodados': [k for k in escolha if k not in res], 'segundos': round(seg), 'globais': GLOBAIS}
        os.makedirs(os.path.join(AQUI, 'saida'), exist_ok=True)
        stamp = datetime.datetime.now().strftime('%d%m%y_%H%M')
        with open(os.path.join(AQUI, 'saida', f'mari_portao_{stamp}.json'), 'w', encoding='utf-8') as fh:
            json.dump({'hash': h, 'detalhe': detalhe, 'log': {k: c.log for k, c in res.items()}}, fh, ensure_ascii=False, indent=1)
        dj = json.dumps(detalhe, ensure_ascii=False).replace('$', '＄')
        mot = (motivo or '').replace('$m$', '')[:300]
        B.sql("insert into public.mari_portao_rodadas (tipo, hash_codigo, modelo, verdes, vermelhos, total, custo_usd, completa, motivo, detalhe) "
              f"values ('bateria', '{h}', '{','.join(modelos) or '?'}', {verdes}, {verm}, {len(escolha)}, {GASTO['usd']:.4f}, "
              f"{'true' if completa else 'false'}, {('$m$' + mot + '$m$') if mot else 'null'}, $j${dj}$j$::jsonb)", escrita=True)
        print(f'\n{verdes}/{len(escolha)} verdes · US$ {GASTO["usd"]:.2f} · {seg / 60:.1f} min · modelo {",".join(modelos) or "?"}')
        if completa and verm == 0:
            print(f'✅ PORTÃO ABERTO para o hash {h} por 6 h — deploy_mari.py codigo/estrutura pode publicar.')
        else:
            print(f'⛔ portão continua fechado{" — " + motivo if motivo else ""}. Vermelho = listar e parar (corrigir é outro passo, com o OK do Ricardo).')


if __name__ == '__main__':
    main()
