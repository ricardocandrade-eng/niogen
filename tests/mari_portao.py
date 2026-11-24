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
        # 10/11 (portão, P3 falso): preço por dia que o 5b · Motor calcula (preco_dia): centavos para cima e o "menos de R$N"
        for v in vs:
            c = -(-round(v * 100) // 30)
            ok.update({round(c / 100, 2), float(c // 100 + 1)})
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
    ja_mandou = any((x.get('interativo') or {}).get('tipo') == 'carrossel' or re.search(r'(?m)^\s*1\)', x.get('mari') or '') for x in c.log[:-1])
    c.exige(ja_mandou or not re.search(r'(planos|opcoes) que (te |eu )?mand', norm(r.get('resposta'))),
            '[P4] disse "os planos que te mandei" sem ter mandado planos')


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


# ───────── rodada única 10/11 (docs/Prompt_mari_rodada_unica_091126_2350.md): P20–P26 ─────────
RX_DESPEDE = re.compile(r'se mudar de ideia|nao quero tomar mais|foi um prazer|quando quiser retomar|qualquer coisa (e|eh) so (me )?chamar')
RX_RS_P31 = re.compile(r'r\$\s*\d')   # P31: nenhum preço na abertura (a cidade ainda não é conhecida)


def ate_planos_jf(c):
    """Varejo em Juiz de Fora até os planos (CEP 36035-130, nº 123, apto 403, referência; sem operadora desde 18/11)."""
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        c.diz('Sim')
    return c.diz('Apto 403, perto da igreja')


def fala(r):
    return norm((r.get('resposta') or '') + ' ' + ((r.get('interativo') or {}).get('corpo') or ''))


def cen_v(c):   # P20 + P21: "tá caro" no Essencial → 2030 + pergunta, sem despedida; 2º "caro" → plano de baixo, sem desconto
    ate_planos_jf(c)
    c.diz('Quero o Essencial')
    r = c.diz('Achei caro')
    t = fala(r)
    c.exige(not r.get('handoff'), f'[P20] encerrou na 1ª objeção de preço: {r.get("handoff")}')
    c.exige('2030' in t, f'[P20] não falou do preço fixo até 2030: «{t[:200]}»')
    c.exige('?' in (r.get('resposta') or '') + ((r.get('interativo') or {}).get('corpo') or ''), f'[P20] não terminou com pergunta: «{t[:200]}»')
    c.exige(not RX_DESPEDE.search(t), f'[P20] despediu-se na objeção: «{t[:200]}»')
    r = c.diz('Continua caro pra mim')
    t = fala(r)
    c.exige(not r.get('handoff'), f'[P21] encerrou no 2º "caro": {r.get("handoff")}')
    c.exige(re.search(r'\bfibra\b', t), f'[P21] não mostrou o plano de baixo (Fibra): «{t[:220]}»')
    c.exige(not re.search(r'descont|abaix|faco por|consigo (te )?fazer', t.replace('unico desconto e o do cartao', '')), f'[P21] falou em desconto: «{t[:220]}»')
    rows = B.sql(f"select dados->>'objecao' o, dados->>'objecoes_n' n from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and rows[0].get('o') == 'preco', f'[P20] objeção não marcada no dados: {rows}')


def cen_w(c):   # P22: plano Fibra + "tá caro" → nunca cita 5G nem Wi-Fi 6
    ate_planos_jf(c)
    c.diz('Quero o Fibra')
    r = c.diz('Tá caro')
    t = fala(r)
    c.exige(not r.get('handoff'), f'[P22] encerrou na objeção: {r.get("handoff")}')
    c.exige(not re.search(r'\b5g\b|wi-?fi 6|chip|chamadas ilimitadas', t), f'[P22] citou 5G/Wi-Fi 6/chip para o Fibra: «{t[:220]}»')
    c.exige('2030' in t, f'[P22] não falou do preço fixo até 2030: «{t[:200]}»')


def cen_x(c):   # P23: "não tenho interesse, pode parar" → despede educado, sem insistir
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('Não tenho interesse, pode parar')
    t = fala(r)
    c.exige((r.get('handoff') or {}).get('motivo') == 'recusa_compra', f'[P23] sem handoff recusa_compra: {r.get("handoff")}')
    c.exige(not re.search(r'\?', (r.get('resposta') or '')), f'[P23] insistiu com pergunta: «{t[:160]}»')


def cen_y(c):   # P24: CEP fora das 38 cidades → 1 balão do texto da Parte 2, sem promessa
    c.diz('Oi')
    r = c.diz('Meu CEP é 01310-100, número 1000')   # São Paulo/SP
    if not r.get('handoff'):
        r = c.diz('Isso, é em São Paulo mesmo')
    t = fala(r)
    bal = r.get('baloes') if isinstance(r.get('baloes'), list) else [r.get('resposta') or '']
    c.exige((r.get('handoff') or {}).get('motivo') == 'fora_de_area', f'[P24] sem handoff fora_de_area: {r.get("handoff")} «{t[:160]}»')
    c.exige(len([b for b in bal if (b or '').strip()]) == 1, f'[P24] mais de 1 balão: {bal}')
    c.exige(not re.search(r'anot|avis|nio vai|televendas|0800', t), f'[P24] promessa/televendas na despedida: «{t[:200]}»')
    c.exige('obrigada pelo contato' in t, f'[P24] sem o texto da Parte 2: «{t[:200]}»')


def cen_z(c):   # P25: golpe da "migração" → texto do golpe + handoff humano
    c.diz('Oi')
    r = c.diz('Recebi uma mensagem dizendo que vou ser migrado pra Claro, é verdade?')
    t = fala(r)
    c.exige('golpe' in t and 'nao migra' in t, f'[P25] sem o texto do golpe: «{t[:200]}»')
    c.exige((r.get('handoff') or {}).get('motivo') == 'pedido_humano', f'[P25] sem handoff humano: {r.get("handoff")}')
    c.exige(not re.search(r'\b(claro|vivo|tim)\b[^.?!]{0,40}(ruim|pior|golpista|mentir)', t), f'[P25] atacou outra operadora: «{t[:200]}»')


def cen_aa(c):   # P26: endereço com "Casa B" → complemento gravado
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        c.diz('Sim')
    c.diz('Casa B, perto da padaria')
    rows = B.sql(f"select complemento from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and 'casa b' in norm(rows[0].get('complemento') or ''), f'[P26] complemento "Casa B" não gravado: {rows}')


def cen_ab(c):   # P27 (12/11, Ricardo): operador decidiu sem_cobertura (portal + DFV) → a Mari avisa, registra interesse, handoff sem_cobertura
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        c.diz('Sim')
    c.diz('Não tem complemento, perto da padaria')
    B.sql(f"update mari_conversas set cobertura_decisao = 'sem_cobertura', nio_viab_em = now(), nio_viab_resultado = 'sem_viabilidade', "
          f"cobertura_em = now() where telefone = '{c.tel}'", escrita=True)
    r = c.diz('Quero o Fibra')
    t = fala(r)
    c.exige((r.get('handoff') or {}).get('motivo') == 'sem_cobertura', f'[P27] sem handoff sem_cobertura: {r.get("handoff")} «{t[:200]}»')
    c.exige(re.search(r'nao chega|ainda nao chegou|nao atende', t), f'[P27] não avisou que a fibra não chega: «{t[:200]}»')
    c.exige(not re.search(r'portal|sistema|consulta|viabilidade|dfv', t), f'[P27] citou portal/sistema/viabilidade: «{t[:200]}»')
    c.exige(not (r.get('interativo') or {}).get('tipo') == 'carrossel', '[P27] mandou os planos para quem não tem cobertura')


def cen_ae(c):   # P30 (13/11, Ricardo; conversa #86): depois do "sem cobertura" a Mari convida a mandar o CEP certo — e tem de cumprir
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        c.diz('Sim')
    B.sql(f"update mari_conversas set cobertura_decisao = 'sem_cobertura', nio_viab_em = now(), nio_viab_resultado = 'sem_viabilidade', "
          f"cobertura_em = now() where telefone = '{c.tel}'", escrita=True)
    r = c.diz('Não tem complemento, perto da padaria')
    c.exige((r.get('handoff') or {}).get('motivo') == 'sem_cobertura', f'[P30] preparo: sem handoff sem_cobertura: {r.get("handoff")}')
    # a cliente repete o CEP e diz que errou (o que a Edilamar fez): a Mari não pode ficar muda nem repetir o "não chega"
    r = c.diz('Me desculpe mandei errado')
    t = fala(r)
    c.exige(t.strip(), '[P30] a Mari ficou muda depois de convidar a mandar o CEP certo')
    c.exige(re.search(r'cep|numero', t), f'[P30] não pediu o CEP ou o número certo: «{t[:200]}»')
    c.exige(not re.search(r'nao chega|ainda nao chegou|nao atende', t), f'[P30] repetiu o aviso de sem cobertura: «{t[:200]}»')
    row = conv_row(c, 'status, handoff_motivo')   # sem endereço novo, a conversa volta a sair (a cadência não persegue quem não tem cobertura)
    c.exige(row.get('status') == 'handoff_realizado' and row.get('handoff_motivo') == 'sem_cobertura', f'[P30] sem endereço novo a conversa devia voltar a sair: {row}')
    # a cliente manda outro endereço: volta para a consulta, sem o veredito antigo
    r = c.diz('O certo é CEP 36015510 número 200')
    t = fala(r)
    row = conv_row(c, 'status, cep, numero, cobertura_decisao, handoff_motivo')
    c.exige(row.get('status') == 'ativo', f'[P30] conversa não voltou a ativa: {row}')
    c.exige(str(row.get('cep') or '').replace('-', '') == '36015510', f'[P30] CEP novo não gravado: {row}')
    c.exige(row.get('cobertura_decisao') != 'sem_cobertura', f'[P30] veredito antigo ficou no endereço novo: {row}')
    c.exige((r.get('handoff') or {}).get('motivo') != 'sem_cobertura', f'[P30] sem cobertura no endereço novo sem consultar: «{t[:200]}»')
    c.exige(not re.search(r'nao chega|ainda nao chegou|nao atende', t), f'[P30] disse que não chega no endereço novo sem consultar: «{t[:200]}»')


def cen_af(c):   # P31 (13/11, medido): a 1ª resposta PEDE O CEP — sem menu, uma mensagem só, e o CEP sozinho segue o fluxo
    # Falha de produção que este cenário reproduz: na janela de 14 dias de 13/11, a 1ª resposta citava o CEP em 35 de 108
    # conversas (o resto saía como "O que você prefere ver primeiro?" + 3 botões) e 37 conversas nunca deram CEP.
    r = c.diz('Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.')
    t = fala(r)
    c.exige(not (r.get('interativo') or {}), f'[P31] 1ª resposta com interativo (menu): {(r.get("interativo") or {}).get("chave")}')
    c.exige('cep' in t, f'[P31] a 1ª resposta não pediu o CEP: «{t[:220]}»')
    c.exige(not re.search(r'prefere ver primeiro|falar com alguem|ver os planos', t), f'[P31] a 1ª resposta ainda oferece o menu: «{t[:220]}»')
    bal = r.get('baloes') if isinstance(r.get('baloes'), list) else [r.get('resposta') or '']
    c.exige(len([b for b in bal if (b or '').strip()]) == 1, f'[P31] abertura em mais de 1 mensagem: {bal}')
    c.exige(not re.search(RX_RS_P31, t), f'[P31] preço na abertura: «{t[:200]}»')
    c.exige(not re.search(r'\bchega\b[^.?!]{0,30}\bsim\b|temos cobertura|atendemos (o|a|seu|sua)', t), f'[P31] prometeu cobertura antes do DFV: «{t[:200]}»')
    c.exige(r.get('modelo') == 'abertura_b2', f'[P31] a abertura passou pelo Claude (modelo {r.get("modelo")!r})')
    # o cliente manda só o CEP: segue o fluxo (pede o número), sem repetir a saudação
    r = c.diz('36035130')
    t = fala(r)
    c.exige(t.strip(), '[P31] a Mari ficou muda depois do CEP')
    c.exige('aqui e a mari' not in t, f'[P31] apresentou-se de novo: «{t[:160]}»')
    c.exige(re.search(r'numero', t), f'[P31] não pediu o número da casa: «{t[:200]}»')
    row = conv_row(c, 'cep, cidade')
    c.exige(str(row.get('cep') or '').replace('-', '') == '36035130', f'[P31] CEP não gravado: {row}')


def cen_ag(c):   # P32 (13/11, visto em produção): nome do contato que não é nome de pessoa → saudação SEM nome
    # Saíram em conversa real: "Oi, Deus, tudo bem?" e "Oi, Pedroernestoromaoptc, tudo bem?". Em todo o resto do
    # sistema nome_confiavel = false quer dizer "não chame por esse nome"; só a abertura usava o nome do WhatsApp.
    # Um nome de pessoa de verdade continua valendo (é o cen_s, "Ana Paula Teste" → "Oi, Ana").
    RUINS = ['Deus', 'Pedroernestoromaoptc', 'Minha Vida', 'Nenem', 'Vovo', 'Zap Novo']
    for i, nome in enumerate(RUINS):
        h = type(c)(f'ag{i}', int(c.tel[-3:]) + i, nome)
        r = h.diz('Oi! Vi o anuncio e quero internet')
        corpo = (r.get('resposta') or '') + ' ' + ((r.get('interativo') or {}).get('corpo') or '')
        p1 = nome.split()[0]
        # só a SAUDAÇÃO (1ª linha): o corpo inteiro tem o botão "Ver minha rua", que contém "minha".
        saudacao = norm(corpo.strip().split('\n')[0])
        h.exige(p1.lower() not in saudacao,
                f'[P32] chamou o cliente de «{p1}» (nome do WhatsApp, não de pessoa): «{corpo[:120]}»')
        h.exige(norm(corpo).startswith('oi, tudo bem?'), f'[P32] saudação sem nome errada para «{nome}»: «{corpo[:80]}»')
        c.falhas += h.falhas
        c.log += h.log


def cen_ah(c):   # P33 (13/11, Ricardo; conversa #88): "vou dar outra chance à operadora X" não é "não quero" → argumenta antes de aceitar
    ate_planos_jf(c)
    r = c.diz('Agradeço, mas darei uma nova chance à Leopoldina net. Obrigado.')
    t = fala(r)
    bruto = (r.get('resposta') or '') + ((r.get('interativo') or {}).get('corpo') or '')
    c.exige(not r.get('handoff'), f'[P33] aceitou a recusa na 1ª vez (concorrente): {r.get("handoff")}')
    c.exige(not RX_DESPEDE.search(t), f'[P33] despediu-se sem argumentar: «{t[:200]}»')
    c.exige('2030' in t, f'[P33] não usou o preço fixo até 2030: «{t[:200]}»')
    c.exige('?' in bruto, f'[P33] não terminou com pergunta: «{t[:200]}»')
    c.exige(not re.search(r'leopoldina', t), f'[P33] citou a outra operadora: «{t[:200]}»')
    r = c.diz('Não quero, obrigado')
    c.exige((r.get('handoff') or {}).get('motivo') == 'recusa_compra', f'[P33] "não quero" explícito sem handoff recusa_compra: {r.get("handoff")}')


def cen_ai(c):   # P34 (13/11, Ricardo; conversa #88): "esse atendimento eu dispenso, quero a empresa" → uma tentativa, sem despedida
    c.diz('Oi')
    c.diz('De onde são vocês')
    r = c.diz('Esse atendimento, eu dispenso, nada com você, e sim com a Empresa. Aliás todas. Obrigado.')
    t = fala(r)
    bruto = (r.get('resposta') or '') + ((r.get('interativo') or {}).get('corpo') or '')
    c.exige((r.get('handoff') or {}).get('motivo') != 'recusa_compra', f'[P34] registrou recusa na 1ª objeção (confiança): {r.get("handoff")}')
    c.exige(not RX_DESPEDE.search(t), f'[P34] despediu-se sem argumentar: «{t[:200]}»')
    c.exige('?' in bruto, f'[P34] não terminou com pergunta: «{t[:200]}»')


def cen_aj(c):   # P35 (16/11, caso Queroly, conversa 138): unidade a confirmar que chega DEPOIS dos planos → a Mari pergunta mesmo assim
    # A viabilidade do portal saiu 6 min depois do carrossel (fila do operador); a regra mandava perguntar a unidade só "na resposta
    # do viável", que já tinha passado — o pedido foi aberto sem o cliente escolher entre Casa A/B/C.
    ate_planos_jf(c)
    c.diz('Quero o plano Nio Essencial')
    B.sql(f"""update mari_conversas set cobertura_decisao = 'viavel', nio_viab_resultado = 'viavel', nio_viab_em = now(),
                 cobertura_detalhe = '{{"portal": "viavel", "unidade_a_confirmar": true, "unidades": ["Apartamento 401", "Apartamento 402", "Apartamento 404"]}}'::jsonb,
                 unidade_conferir = '{{"motivo": "escolher", "lista": ["Apartamento 401", "Apartamento 402", "Apartamento 404"], "informada": "Apto 403", "usada": "Apartamento 401", "autor": "portao"}}'::jsonb,
                 unidade_conferir_em = now()
           where id = (select id from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1)""", escrita=True)
    r = c.diz('Ana Teste da Silva, CPF 529.982.247-25')
    t = fala(r)
    c.exige(re.search(r'40[124]', t), f'[P35] não mostrou as unidades do cadastro da Nio depois dos planos: «{t[:220]}»')
    c.exige(not re.search(r'apartamento 401[^?]{0,40}(certo|confirmad)', t), f'[P35] escolheu a unidade pelo cliente: «{t[:220]}»')


def cen_ak(c):   # P36 + P37 (16/11, caso Queroly): e-mail já confirmado não se pede de novo; a forma dita junto com o plano não se pergunta
    ate_planos_jf(c)
    c.diz('Quero o plano Nio Essencial')
    c.diz('Ana Teste da Silva, CPF 529.982.247-25')
    c.diz('anateste@gmail.com')
    c.diz('Sim')
    r = c.diz('Quero 800 mega 125 no cartão')
    t = fala(r)
    c.exige(not re.search(r'e-?mail', t) or 'anateste@gmail.com' in t and not re.search(r'me passa|qual (e )?(o )?seu|pode mandar', t),
            f'[P36] pediu de novo o e-mail já confirmado: «{t[:220]}»')
    c.exige((r.get('interativo') or {}).get('chave') != 'pagamento', f'[P37] perguntou a forma que o cliente acabou de dizer (cartão): «{t[:200]}»')
    row = conv_row(c, 'forma_pagamento')
    c.exige(row.get('forma_pagamento') == 'cartao', f'[P37] não gravou cartão: {row}')


def cen_ac(c):   # P28 (12/11, Ricardo): pedido Nio em andamento no CPF → a Mari pergunta se procede, anota e segue
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        c.diz('Sim')
    c.diz('Não tem complemento, perto da padaria')
    c.diz('Quero o Fibra')
    B.sql(f"update mari_conversas set nio_pedido_aberto = 'sim', nio_pedido_aberto_em = now(), dup_consultas = 1 where telefone = '{c.tel}'", escrita=True)
    r = c.diz('Ana Teste da Silva, CPF 529.982.247-25')
    t = fala(r)
    c.exige(re.search(r'pedido[^.?!]{0,60}(andamento|aberto)', t), f'[P28] não perguntou do pedido em andamento: «{t[:220]}»')
    c.exige(not r.get('handoff'), f'[P28] encerrou/handoff ao perguntar do pedido: {r.get("handoff")}')
    c.exige(not re.search(r'portal|sistema|consta|vi aqui', t), f'[P28] citou portal/sistema/"consta": «{t[:200]}»')
    r = c.diz('Fui eu sim, mas desisti daquele, quero esse agora')
    rows = B.sql(f"select dados->>'pedido_aberto_resposta' p from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and rows[0].get('p'), f'[P28] resposta do cliente sobre o pedido não foi anotada: {rows}')
    c.exige(not r.get('handoff'), f'[P28] não seguiu o atendimento depois da resposta: {r.get("handoff")}')


def cen_ad(c):   # P29 (12/11 ~10h; rev. 15/11, Ricardo — caso Grace): crédito negado → aviso gentil + titular parente e PASSA PARA O BKO
    #                (o BKO faz o pedido no CPF do parente; a Mari não troca o titular nem roda a 2ª consulta sozinha)
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        c.diz('Sim')
    c.diz('Não tem complemento, perto da padaria')
    c.diz('Quero o Fibra')
    c.diz('Bia Teste da Silva, CPF 529.982.247-25')
    r = c.diz('bia.teste@exemplo.com')
    if 'bia.teste@exemplo.com' in norm((r.get('resposta') or '') + ' ' + ((r.get('interativo') or {}).get('corpo') or '')):
        r = c.diz('Sim, está certinho')
    c.exige((r.get('interativo') or {}).get('chave') == 'pagamento', f'[P29] não foi direto ao pagamento (sem pergunta de autorização): {(r.get("interativo") or {}).get("chave")}')
    c.exige(not re.search(r'autoriza', fala(r)), f'[P29] falou de autorização: «{fala(r)[:160]}»')
    B.sql(f"update mari_conversas set credito_resultado = 'negado', credito_em = now(), credito_consultas = 1 where telefone = '{c.tel}'", escrita=True)
    r = c.diz('Boleto bancário')
    t = fala(r)
    c.exige(re.search(r'parente|familiar', t) and re.search(r'nao aprovou', t), f'[P29] não ofereceu o CPF de parente: «{t[:220]}»')
    c.exige(r.get('handoff'), f'[P29] não passou para o BKO no 1º negado: {r.get("handoff")}')
    c.exige(re.search(r'biometria', t), f'[P29] não avisou que a biometria é do titular: «{t[:220]}»')
    c.exige(not re.search(r'serasa|score|spc|nome sujo', t), f'[P29] falou de Serasa/score: «{t[:200]}»')
    r = c.diz('Pode ser minha mãe: Maria Teste da Silva, CPF 111.444.777-35')
    rows = B.sql(f"select dados->>'cpf' cpf, credito_resultado from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and (rows[0].get('cpf') or '').replace('.', '').replace('-', '') == '52998224725' and rows[0].get('credito_resultado') == 'negado',
            f'[P29] depois do handoff a Mari trocou o CPF / rodou a 2ª consulta sozinha: {rows}')


def cen_al(c):   # P38 (17/11, Ricardo): cliente que já é Nio, irritado → canais oficiais + despedida, nunca uma pessoa (somos revenda)
    c.diz('Oi')
    r = c.diz('Sou cliente Nio e minha internet tá caindo toda hora, ninguém da Nio resolve, tô revoltado! Quero falar com alguém agora')
    t = fala(r)
    c.exige((r.get('handoff') or {}).get('motivo') == 'ja_cliente_nio', f'[P38] cliente Nio não foi encerrado como ja_cliente_nio: {r.get("handoff")}')
    c.exige(re.search(r'app nio|0800', t), f'[P38] não indicou os canais oficiais da Nio: «{t[:220]}»')
    c.exige(not re.search(r'consultor|vou te passar|nosso time (vai|te)|em ate 2 horas', t), f'[P38] prometeu atendimento nosso: «{t[:220]}»')


def ate_dados_sem_referencia(c):
    """JF até os planos SEM dar ponto de referência; devolve a fala depois do complemento (já com os planos, desde 18/11)."""
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        c.diz('Sim')
    return c.diz('Apto 403')


def ate_pedir_referencia(c, max_falas=7):
    """Do plano escolhido até a Mari pedir a referência (ou mandar o resumo). Devolve (pediu, resumo_sem_ref, ultima)."""
    falas = ['Quero o plano Nio Essencial', 'Ana Teste da Silva, CPF 529.982.247-25', 'anateste@gmail.com', 'Sim',
             'Boleto bancário', 'Qualquer dia, de tarde', 'Tarde']
    r = {}
    for f in falas[:max_falas]:
        r = c.diz(f)
        t = fala(r)
        if re.search(r'referencia', t):
            return True, False, r
        if (r.get('interativo') or {}).get('chave') == 'resumo' or re.search(r'confere os dados', t):
            return False, True, r
    return False, False, r


def cen_am(c):   # P39 (18/11, auditoria do funil): 6 de 8 leads parados em Viabilidade travaram no pedido de referência ANTES dos planos
    r_comp = ate_dados_sem_referencia(c)
    t = fala(r_comp)
    c.exige(not re.search(r'referencia', t), f'[P39] pediu ponto de referência antes dos planos: «{t[:220]}»')
    # 18/11 (Ricardo): sem pergunta de operadora — do complemento direto aos planos.
    c.exige(not re.search(r'operadora', t), f'[P39] perguntou a operadora (removida em 18/11): «{t[:220]}»')
    mostrou = (r_comp.get('interativo') or {}).get('tipo') == 'carrossel' or re.search(r'(?m)^\s*1\)', r_comp.get('resposta') or '')
    c.exige(mostrou, f'[P39] não mostrou os planos depois do complemento: «{t[:220]}»')
    pediu, resumo_sem_ref, ult = ate_pedir_referencia(c)
    c.exige(not resumo_sem_ref, f'[P39] mandou o resumo sem pedir a referência: «{fala(ult)[:220]}»')
    c.exige(pediu, f'[P39] não pediu a referência antes do resumo (Passo 4, item 7): «{fala(ult)[:220]}»')
    if pediu:
        r = c.diz('Não tem')
        t = fala(r)
        c.exige(not re.search(r'referencia', t), f'[P39] insistiu na referência depois do "não tem": «{t[:220]}»')


def cen_an(c):   # P40 (18/11, conversas reais 5308592e, 70afef39, b85cfce7): referência que cita outra rua NÃO vira "rua divergente"
    ate_dados_sem_referencia(c)
    pediu, _, ult = ate_pedir_referencia(c)
    c.exige(pediu, f'[P40] não chegou à pergunta da referência: «{fala(ult)[:220]}»')
    r = c.diz('Perto da Avenida Rio Branco, atrás da farmácia')
    t = fala(r)
    c.exige(not re.search(r'(sua rua e essa|essa mesma ou e|e a avenida rio branco)', t),
            f'[P40] tratou a referência como rua do cliente: «{t[:220]}»')
    row = conv_row(c, "dados->>'referencia' as referencia")
    c.exige('rio branco' in norm(row.get('referencia') or ''), f'[P40] referência não gravada: {row}')


RX_PEDE_DADOS = re.compile(r'nome completo|\bcpf\b')


def cen_ao(c):   # P41 + P42 (21/11, Ricardo; conversa L-222, #202): upsell + CPF juntos; "Am n entende" virou o nome
    # A Mari sugeriu o Super e, na mesma mensagem, pediu nome e CPF; a cliente respondeu "Am n entende", a explicação pediu o CPF
    # de novo, e a frase foi gravada como nome (a Mari passou a chamá-la de "Am").
    ate_planos_jf(c)
    r = c.diz('Quero o plano Nio Essencial')
    t = fala(r)
    teve_upsell = 'por mais r$' in t
    if teve_upsell:
        c.exige(not RX_PEDE_DADOS.search(t), f'[P41] pediu nome/CPF junto com a sugestão: «{t[-220:]}»')
        c.exige((r.get('interativo') or {}).get('chave') == 'upsell', f'[P41] sugestão sem os botões fica/troca: «{t[-160:]}»')
    r = c.diz('Am n entende')
    t = fala(r)
    if teve_upsell:
        c.exige(not RX_PEDE_DADOS.search(t), f'[P41] "não entendi" e pediu nome/CPF sem a resposta do upsell: «{t[-220:]}»')
        c.exige((r.get('interativo') or {}).get('chave') == 'upsell', f'[P41] não perguntou de novo "fica ou troca": «{t[-160:]}»')
    row = conv_row(c, "dados->>'nome' as nome")
    c.exige(not row.get('nome'), f'[P42] a frase "Am n entende" virou nome: {row}')
    if teve_upsell:
        r = c.diz('Fico no Essencial')
        t = fala(r)
        c.exige(RX_PEDE_DADOS.search(t), f'[P41] respondeu "fico" e a Mari não pediu nome/CPF: «{t[-220:]}»')
    c.diz('529.982.247-25')
    r = c.diz('Gizele Odile Teste')
    row = conv_row(c, "dados->>'nome' as nome, plano_escolhido, dados->>'upsell_resposta' as up")
    c.exige(row.get('nome') == 'Gizele Odile Teste', f'[P42] nome certo não gravado: {row}')
    c.exige('ESS' in str(row.get('plano_escolhido') or ''), f'[P41] o plano mudou sem o cliente pedir: {row}')
    c.exige(not re.search(r'\bam\b', fala(r)), f'[P42] chamou a cliente de "Am": «{fala(r)[:160]}»')


def cen_ap(c):   # P43 (21/11, conversa L-222): a unidade que o cliente deu está na lista da Nio → não se pergunta de novo
    # O portal consultou antes do "Casa A" chegar e abriu a conferência; a Mari perguntou "Casa A, B ou C?" 2 vezes (uma no meio do chip).
    ate_planos_jf(c)
    comp = conv_row(c, 'complemento').get('complemento') or 'Apto 403'
    lista = json.dumps(['Apto 401', comp, 'Apto 404'], ensure_ascii=False).replace("'", "''")
    B.sql(f"""update mari_conversas set cobertura_decisao = 'viavel', nio_viab_resultado = 'viavel', nio_viab_em = now(),
                 cobertura_detalhe = jsonb_build_object('portal', 'viavel', 'unidade_a_confirmar', true, 'unidades', '{lista}'::jsonb),
                 unidade_conferir = jsonb_build_object('motivo', 'escolher', 'lista', '{lista}'::jsonb, 'usada', 'Apto 401', 'autor', 'portao'),
                 unidade_conferir_em = now()
           where id = (select id from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1)""", escrita=True)
    for msg in ('Quero o plano Nio Essencial', 'Tem chip?'):
        r = c.diz(msg)
        t = fala(r)
        c.exige(not re.search(r'\b40[14]\b', t), f'[P43] perguntou de novo a unidade que já está na lista ({msg!r}): «{t[:220]}»')
        c.exige((r.get('interativo') or {}).get('chave') != 'unidade', f'[P43] botões de unidade com a unidade já certa ({msg!r})')



def data_btn():
    """Botão de data como a Mari oferece (D+1, sem domingo): 'Sáb, 21/11'."""
    hoje = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-3))).date()
    d = hoje + datetime.timedelta(days=1)
    if d.weekday() == 6:
        d += datetime.timedelta(days=1)
    return f"{['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'][d.weekday()]}, {d:%d/%m}"


RX_PERG_PERIODO = re.compile(r'qual (turno|periodo)|periodo (voce )?prefere|manha ou (a |de )?tarde')


def cen_aq(c):   # P44 (19/11, conversa L-217, Jussara): o cliente respondeu "Manhã" antes do nome e a Mari perguntou o período mais 2 vezes
    # A Mari pediu nome e CPF junto com os botões de data; a cliente mandou o CPF, tocou a data e "Manhã" — e as duas falas
    # seguintes (pedindo o nome, depois o e-mail) voltaram com "E qual período você prefere nesse dia?" e os botões.
    ate_planos_jf(c)
    r = c.diz('Quero o plano Nio Essencial')
    if 'por mais r$' in fala(r):
        c.diz('Fico no Essencial')
    c.diz('Boleto')
    c.diz('529.982.247-25')
    c.diz(data_btn())
    c.diz('Manhã')
    for msg in ('Ana Teste da Silva', 'anateste@gmail.com', 'Sim'):
        r = c.diz(msg)
        t = fala(r)
        c.exige((r.get('interativo') or {}).get('chave') != 'turno', f'[P44] botões de período de novo depois do "Manhã" ({msg!r}): «{t[-160:]}»')
        c.exige(not RX_PERG_PERIODO.search(t), f'[P44] perguntou o período de novo depois do "Manhã" ({msg!r}): «{t[-200:]}»')
    row = conv_row(c, 'instalacao_preferencia')
    c.exige('manha' in norm(row.get('instalacao_preferencia') or ''), f'[P44] o período "Manhã" não ficou gravado: {row}')

def data_futura(dias):
    hoje = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-3))).date()
    return hoje + datetime.timedelta(days=dias)


def cen_ar(c):   # P45 (20/11, conversa L-199, Bruno): "temos até dia 18/12 para tomar decisões" e nada foi gravado
    # A Mari entendeu (estava no briefing), mas não emitiu o [AGENDAMENTO_RETORNO], e o C3 do banco descartava a data:
    # o lead seguia na escada e no 🔥 O10. Agora: a data do cliente fica gravada, a espera (⏸) nasce sozinha (0348) e a
    # despedida diz que A GENTE chama perto do dia (nunca "é só me chamar").
    d = data_futura(27)
    ate_planos_jf(c)
    r = c.diz('Existe possibilidade de trocar os chips por outra coisa?')
    msg = f'Vou decidir com calma, temos até dia {d:%d/%m} para tomar decisões, pq nossa mudança será dia {(d - datetime.timedelta(days=1)):%d/%m}'
    r = c.diz(msg)
    row = conv_row(c, 'agendamento_retorno, espera_ate, espera_motivo, espera_por')
    if not row.get('espera_ate'):   # pode contornar uma vez antes de aceitar
        r = c.diz(f'Prefiro decidir mais perto mesmo, até dia {d:%d/%m}')
        row = conv_row(c, 'agendamento_retorno, espera_ate, espera_motivo, espera_por')
    t = fala(r)
    c.exige(bool(row.get('espera_ate')), f'[P45] o cliente deu o dia {d:%d/%m} e a conversa não ficou em espera: {row}')
    c.exige(f'{d:%d/%m}' in str(row.get('espera_motivo') or ''), f'[P45] o motivo da espera não traz a data do cliente: {row}')
    c.exige(not row.get('espera_por'), f'[P45] a espera devia ser marcada pela Mari (espera_por vazio): {row}')
    c.exige(not re.search(r'(e so|so) (me )?(chamar|mandar um oi)', t), f'[P45] despedida com "é só me chamar" — quem chama perto do dia é a gente: «{t[-200:]}»')
    r = c.diz('😉')
    row2 = conv_row(c, 'espera_ate')
    c.exige(bool(row2.get('espera_ate')), f'[P45] o "😉" depois da despedida derrubou a espera: {row2}')


def cen_as(c):   # P46 (21/11, conversa L-236, teste do Ricardo): a lista de unidades chegou depois do período; a Mari perguntou
    # a unidade e, na mesma fala, "E qual período você prefere nesse dia?" de novo (o "Manhã" já tinha vindo).
    ate_planos_jf(c)
    r = c.diz('Quero o plano Nio Fibra')
    if 'por mais r$' in fala(r):
        c.diz('Fico no Fibra')
    c.diz('Boleto')
    c.diz('Ana Teste da Silva, 529.982.247-25')
    c.diz('anateste@gmail.com')
    c.diz(data_btn())
    lista = json.dumps(['Apartamento 101', 'Apartamento 102', 'Apartamento 201'], ensure_ascii=False).replace("'", "''")
    B.sql(f"""update mari_conversas set cobertura_decisao = 'viavel', nio_viab_resultado = 'viavel', nio_viab_em = now(), complemento = null,
                 cobertura_detalhe = jsonb_build_object('portal', 'viavel', 'unidade_a_confirmar', true, 'unidades', '{lista}'::jsonb),
                 unidade_conferir = jsonb_build_object('motivo', 'escolher', 'lista', '{lista}'::jsonb, 'usada', 'Apartamento 101', 'autor', 'portao'),
                 unidade_conferir_em = now()
           where id = (select id from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1)""", escrita=True)
    r = c.diz('Manhã')
    t = fala(r)
    c.exige(re.search(r'apartamento 10[12]|\b10[12]\b', t), f'[P46] a lista de unidades chegou e a Mari não perguntou a unidade: «{t[:220]}»')
    c.exige((r.get('interativo') or {}).get('chave') != 'turno', f'[P46] botões de período de novo depois do "Manhã": «{t[-160:]}»')
    c.exige(not RX_PERG_PERIODO.search(t), f'[P46] perguntou o período de novo junto com a unidade: «{t[-220:]}»')
    row = conv_row(c, 'instalacao_preferencia')
    c.exige('manha' in norm(row.get('instalacao_preferencia') or ''), f'[P46] o período "Manhã" não ficou gravado: {row}')
    r = c.diz('Não é nenhuma dessas, é o 403')
    t = fala(r)
    c.exige(not RX_PERG_PERIODO.search(t) and (r.get('interativo') or {}).get('chave') != 'turno', f'[P46] período de novo depois da unidade: «{t[-200:]}»')


def cen_at(c):   # P47 (23/11, conversa L-259): rua com erro de digitação e cliente que não sabe o CEP
    # A cliente escreveu "Travessa gorasiu de Castro Brandão" (o cadastro é "Rua Gorasil de Castro Brandão", CEP 36506-150). A busca
    # voltou vazia (e, sem a cidade dos planos, ia para Juiz de Fora); a Mari pediu o CEP 3 vezes, disse que "só com o nome da rua
    # não consigo" e seguiu para o CPF sem endereço, sem cobertura e sem plano.
    c.diz('Olá! Posso ter mais informações sobre isso?')
    c.diz('💰 Ver os planos')
    c.diz('Uba Minas Gerais')
    r = c.diz('Travessa gorasiu de Castro Brandão número 120 bairro centro')
    t = fala(r)
    row = conv_row(c, "cep, numero, dados->'opcoes_rua' as opcoes")
    cep = str(row.get('cep') or '').replace('-', '')
    opc = row.get('opcoes') or []
    if isinstance(opc, str):
        opc = json.loads(opc)
    ceps = [str(o.get('cep') or '').replace('-', '') for o in opc]
    c.exige(cep == '36506150' or '36506150' in ceps, f'[P47] a rua com erro de digitação não foi achada (cep={cep!r}, opções={ceps}): «{t[:220]}»')
    c.exige(not re.search(r'nao (consegui|achei|encontrei)|so (com|pel)o nome', t), f'[P47] disse que não achou a rua: «{t[:220]}»')
    c.exige('gorasil' in t, f'[P47] não mostrou a rua achada ao cliente: «{t[:220]}»')
    if cep != '36506150' and '36506150' in ceps:
        c.diz(str(ceps.index('36506150') + 1))
        row = conv_row(c, 'cep, numero')
        cep = str(row.get('cep') or '').replace('-', '')
    c.exige(cep == '36506150', f'[P47] o CEP da rua escolhida não foi gravado: {row}')
    c.exige(str(row.get('numero') or '') == '120', f'[P47] o número 120, dito junto da rua, se perdeu: {row}')


def cen_au(c):   # P48 (23/11, conversa L-259): rua que não existe no cadastro + "não sei o CEP" → consultor na hora, sem pedir CPF
    # A Mari pediu o CEP 3 vezes, disse que "só com o nome da rua não consigo" e seguiu para nome, CPF, e-mail e pagamento sem
    # endereço, sem cobertura e sem plano; o time recebeu "VENDA PRONTA". Agora: passa ao consultor, que localiza o endereço.
    c.diz('Olá! Posso ter mais informações sobre isso?')
    c.diz('💰 Ver os planos')
    c.diz('Uba Minas Gerais')
    r = c.diz('Rua Zebulon Xavier Quaresma, 10')
    t = fala(r)
    c.exige(not RX_PEDE_DADOS.search(t), f'[P48] pediu nome/CPF sem ter o endereço: «{t[:220]}»')
    c.exige(not re.search(r'so (com|pel)o nome', t), f'[P48] disse que não dá pra buscar pelo nome: «{t[:220]}»')
    r = c.diz('Eu não sei o cep')
    t = fala(r)
    h = r.get('handoff') or {}
    c.exige(h.get('motivo') == 'pedido_humano', f'[P48] não passou ao consultor (handoff={h.get("motivo")!r}): «{t[:220]}»')
    c.exige('localizar o seu endereco' in t, f'[P48] fala sem "localizar o seu endereço": «{t[:220]}»')
    c.exige(not RX_PEDE_DADOS.search(t), f'[P48] pediu nome/CPF: «{t[:220]}»')
    row = conv_row(c, 'status, handoff_briefing')
    c.exige(row.get('status') == 'handoff_realizado', f'[P48] conversa não ficou com o time: {row.get("status")!r}')
    b = row.get('handoff_briefing') or ''
    c.exige('VENDA PRONTA' not in b and 'Achar o CEP' in b, f'[P48] aviso ao time errado: «{b[:260]}»')


def cen_av(c):   # P49 (24/11, conversa L-276, Nelma, #241): cidade fora da área dita pelo texto → encerra, sem pedir CEP
    # No "💰 Ver os planos" a Mari pediu a cidade; a cliente respondeu "Cabo Frio no pêro" e a Mari pediu o CEP e o número
    # "pra confirmar se a Nio atende", depois confirmou "Peró, em Cabo Frio?" ("Sim") e ainda esperou o CEP. Ricardo: "A cidade
    # em si já é o filtro e ela deveria descartar e encerrar o atendimento."
    c.diz('Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.')
    c.diz('💰 Ver os planos')
    r = c.diz('Cabo Frio no pêro')
    t = fala(r)
    c.exige(not re.search(r'\bcep\b|numero da casa', t), f'[P49] pediu CEP/número para cidade fora da área: «{t[:220]}»')
    if not r.get('handoff'):   # no máximo uma confirmação da cidade, quando a Mari tiver dúvida
        r = c.diz('Sim')
        t = fala(r)
    c.exige((r.get('handoff') or {}).get('motivo') == 'fora_de_area', f'[P49] não encerrou como fora_de_area: {r.get("handoff")} «{t[:220]}»')
    c.exige('obrigada pelo contato' in t and 'cabo frio' in t, f'[P49] despedida sem o texto da Parte 2: «{t[:220]}»')
    c.exige(not re.search(r'\bcep\b', t), f'[P49] a despedida pede CEP: «{t[:220]}»')


def cen_aw(c):   # P50 (24/11, abertura B4 — trava pedida pelo Ricardo, 11h55: "muito cuidado com isso"): a abertura disse "a partir de
    # R$ 110" (Regular) e o cliente é de cidade BTU (Oferta 50 %) → o que sai é o preço DA CIDADE (R$ 55–100), nunca o R$ 110 repetido.
    # A rota de teste não tem referral de anúncio: o preço da abertura é gravado como o 5b grava (dados.abertura_preco).
    c.diz('Oi! Vi o anúncio e quero saber mais.')
    B.sql(f"""update mari_conversas set dados = coalesce(dados, '{{}}'::jsonb) || '{{"abertura_preco": 110, "abertura_preco_cluster": "regular"}}'::jsonb """
          f"where telefone = '{c.tel}'", escrita=True)
    c.diz('🏡 Pra minha casa')
    r = c.diz('Moro em Araguari, quero ver os planos')
    t = fala(r)
    if not re.search(r'r\$\s*\d', t):   # a Mari pode pedir o CEP antes dos planos — o preço só sai com a cidade
        r = c.diz('O CEP é 38440-000, número 100')
        t = fala(r)
        if not re.search(r'r\$\s*\d', t):
            r = c.diz('Sim')
            t = fala(r)
    c.exige(not re.search(r'r\$\s*110\b', t), f'[P50] repetiu o R$ 110 da abertura numa cidade BTU: «{t[:260]}»')
    c.exige(not re.search(r'no cart[aã]o', t), f'[P50] citou desconto do cartão numa cidade BTU: «{t[:260]}»')


def cen_ax(c):   # P51 (24/11, conversa L-82, Michele, #76 — 16/11 17h17): o consultor falou com a cliente e depois a Mari respondeu
    # com "[Mensagem do consultor da equipe, enviada enquanto ele atendia]" e as falas dele copiadas. A marca e as falas do time nunca
    # saem na voz da Mari. As falas do consultor entram como entram na produção (mari_turnos, papel humano).
    c.diz('Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.')
    B.sql("insert into mari_turnos (conversa_id, papel, texto, pendente) "
          f"select id, 'humano', t, false from mari_conversas, unnest(array['Boa noite, tudo bem?', "
          f"'Consegui verificar aqui, me dá só um minutinho que já te retorno']) t where telefone = '{c.tel}'", escrita=True)
    r = c.diz('Oiii')
    t = fala(r)
    c.exige('mensagem do consultor' not in t, f'[P51] a marca interna do consultor saiu para o cliente: «{t[:260]}»')
    c.exige('me da so um minutinho' not in t and 'me dá só um minutinho' not in t,
            f'[P51] a Mari repetiu a fala do consultor: «{t[:260]}»')


# cenário → (índice do telefone, função, P# que cobre). Índices iguais aos da mari_v7_bateria; q = 15.
PORTAO = {
    'a': (1, B.cen_a, 'P1 P5 P7 P17'), 'c': (2, B.cen_c, 'P2'), 'd': (3, B.cen_d, 'regressão DFV'), 'e': (4, B.cen_e, 'regressão DFV'),
    'g': (5, B.cen_g, 'regressão já-Nio'), 'h': (6, B.cen_h, 'sem pergunta de operadora (18/11)'), 'i': (7, B.cen_i, 'regressão botão'),
    'j': (8, cen_j_portao, 'regressão BTU + P18'), 'k': (9, cen_k_portao, 'P1 P2 P4'), 'l': (10, B.cen_l, 'P3'),
    'm': (11, B.cen_m, 'regressão rua longa'), 'n': (12, B.cen_n, 'P3'), 'o': (13, cen_o_portao, 'P5 P7 P8 P9 P11 P13 P14 P16'),
    'p': (14, cen_p_portao, 'P9 P10 P19'), 'q': (15, cen_q, 'P15'),
    # 08/11 — abertura B2 (saudação fixa + 3 botões): sem nome, com nome, 1ª mensagem já com CEP, toque em cada botão.
    'r': (16, B.cen_r, 'B2 sem nome'), 's': (17, B.cen_s, 'B2 com nome'), 't': (18, B.cen_t, 'B2 com CEP'), 'u': (19, B.cen_u, 'B2 botões'),
    # 10/11 — rodada única (u usa 19 e 20): objeções, fora de área, golpe, complemento
    'v': (21, cen_v, 'P20 P21'), 'w': (22, cen_w, 'P22'), 'x': (23, cen_x, 'P23'), 'y': (24, cen_y, 'P24'), 'z': (25, cen_z, 'P25'),
    'aa': (26, cen_aa, 'P26'),
    # 12/11 — operador na Mari (cobertura pela decisão da tela; pedido Nio em andamento no CPF)
    'ab': (27, cen_ab, 'P27'), 'ac': (28, cen_ac, 'P28'),
    'ad': (29, cen_ad, 'P29'),
    # 13/11 — conversa #86: cliente volta depois do "sem cobertura"
    'ae': (30, cen_ae, 'P30'),
    # 13/11 — a 1ª resposta pede o CEP (0188): o menu da B2 não perguntava nada e 1/3 das conversas morria sem CEP
    'af': (31, cen_af, 'P31'),
    # 13/11 — "Oi, Deus" e "Oi, Pedroernestoromaoptc" em conversa real: nome do WhatsApp que não é nome de pessoa
    'ag': (40, cen_ag, 'P32'),
    # 13/11 — conversa #88: recusa com motivo fora da lista de objeções (concorrente, confiança) virava despedida na 1ª vez
    'ah': (41, cen_ah, 'P33'), 'ai': (42, cen_ai, 'P34'),
    # 16/11 — caso Queroly (conversa 138): unidade depois dos planos, e-mail repetido, forma já dita
    'aj': (43, cen_aj, 'P35'), 'ak': (44, cen_ak, 'P36 P37'),
    # 17/11 — cliente que já é Nio: encerra com os canais oficiais, em qualquer tom (somos revenda)
    'al': (45, cen_al, 'P38'),
    # 18/11 — auditoria do funil: ponto de referência só depois dos planos; referência com outra rua não é a rua do cliente
    'am': (46, cen_am, 'P39'), 'an': (47, cen_an, 'P40'),
    # 21/11 — conversa L-222 (#202): upsell sem pedir CPF junto; frase não vira nome; unidade da lista não se pergunta de novo
    'ao': (48, cen_ao, 'P41 P42'), 'ap': (49, cen_ap, 'P43'),
    # 21/11 — conversa L-217 (Jussara): período respondido antes do nome não se pergunta de novo
    'aq': (50, cen_aq, 'P44'),
    # 21/11 — conversa L-199 (Bruno): o cliente dá um dia para decidir → espera marcada pela Mari (0348)
    'ar': (51, cen_ar, 'P45'),
    # 21/11 — conversa L-236 (teste do Ricardo): a lista de unidades chega depois do período; o período não se pergunta de novo
    'as': (52, cen_as, 'P46'),
    # 23/11 — conversa L-259: rua com erro de digitação, cliente sem CEP; cidade dos planos entra na busca
    'at': (53, cen_at, 'P47'),
    # 23/11 — conversa L-259: rua não achada + "não sei o CEP" → consultor na hora (nunca segue para o CPF sem endereço)
    'au': (54, cen_au, 'P48'),
    # 24/11 — conversa L-276 (Nelma, #241): cidade fora da área dita pelo texto → fora_de_area na hora, sem pedir CEP
    'av': (55, cen_av, 'P49'),
    # 24/11 — abertura B4: preço "a partir de" na abertura + cliente de cidade BTU → o preço da cidade, nunca o da abertura
    'aw': (56, cen_aw, 'P50'),
    # 24/11 — conversa L-82 (Michele, #76): a marca "[Mensagem do consultor…]" e as falas do time não saem na voz da Mari
    'ax': (57, cen_ax, 'P51'),
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
