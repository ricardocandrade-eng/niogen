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


def ate_planos_jf(c):
    """Varejo em Juiz de Fora até a escolha do plano (CEP 36035-130, nº 123, apto 403, referência, operadora)."""
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        c.diz('Sim')
    c.diz('Apto 403, perto da igreja')
    return c.diz('Claro')


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
    r = c.diz('Uso a Vivo')
    t = fala(r)
    c.exige((r.get('handoff') or {}).get('motivo') == 'sem_cobertura', f'[P27] sem handoff sem_cobertura: {r.get("handoff")} «{t[:200]}»')
    c.exige(re.search(r'nao chega|ainda nao chegou|nao atende', t), f'[P27] não avisou que a fibra não chega: «{t[:200]}»')
    c.exige(not re.search(r'portal|sistema|consulta|viabilidade|dfv', t), f'[P27] citou portal/sistema/viabilidade: «{t[:200]}»')
    c.exige(not (r.get('interativo') or {}).get('tipo') == 'carrossel', '[P27] mandou os planos para quem não tem cobertura')


def cen_ac(c):   # P28 (12/11, Ricardo): pedido Nio em andamento no CPF → a Mari pergunta se procede, anota e segue
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        c.diz('Sim')
    c.diz('Não tem complemento, perto da padaria')
    c.diz('Uso a Claro')
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


def cen_ad(c):   # P29 (12/11 ~10h, Ricardo): crédito negado → aviso gentil + CPF de parente (sem handoff); o CPF novo vira titular
    c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        c.diz('Sim')
    c.diz('Não tem complemento, perto da padaria')
    c.diz('Uso a Claro')
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
    c.exige(not r.get('handoff'), f'[P29] passou para humano no 1º negado: {r.get("handoff")}')
    c.exige(not re.search(r'serasa|score|spc|nome sujo', t), f'[P29] falou de Serasa/score: «{t[:200]}»')
    r = c.diz('Pode ser minha mãe: Maria Teste da Silva, CPF 111.444.777-35')
    rows = B.sql(f"select dados->>'cpf' cpf, credito_resultado, credito_em from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and (rows[0].get('cpf') or '').replace('.', '').replace('-', '') == '11144477735' and rows[0].get('credito_resultado') is None,
            f'[P29] CPF do parente não virou titular / crédito não voltou à fila: {rows}')


# cenário → (índice do telefone, função, P# que cobre). Índices iguais aos da mari_v7_bateria; q = 15.
PORTAO = {
    'a': (1, B.cen_a, 'P1 P5 P7 P17'), 'c': (2, B.cen_c, 'P2'), 'd': (3, B.cen_d, 'regressão DFV'), 'e': (4, B.cen_e, 'regressão DFV'),
    'g': (5, B.cen_g, 'regressão já-Nio'), 'h': (6, B.cen_h, 'regressão operadora'), 'i': (7, B.cen_i, 'regressão botão'),
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
