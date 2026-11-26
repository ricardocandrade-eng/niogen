// NIOGEN | supabase/functions/ferramentas-vigia/index.ts | 26/11/2026 — Claude Code (Opus 5.5) · migration 0415_ferramentas
// Vigia das FERRAMENTAS pagas: de hora em hora (pg_cron `ferramentas_vigia`) confere cada ferramenta cadastrada em `ferramentas`
// e grava pela RPC ferramentas_registrar. Também lê o dólar comercial para a tela pôr tudo em R$.
//   http            → a página responde 2xx?
//   chatwoot_api    → GET /api do Chatwoot: queue_services e data_services "ok"
//   statuspage      → status.json da página de status do fornecedor (indicator none / minor / major / critical)
//   rdap            → RDAP do Registro.br: data de expiração do domínio (vira o vencimento)
//   vultr_conta     → API da Vultr: saldo e cobranças pendentes (segredo VULTR_API_KEY)
//   vultr_instancia → API da Vultr: a VPS daquele IP está ligada?
// O n8n (vigia de 2 em 2 min) e a Meta (saldo coletado pelo n8n) são lidos direto no banco pela tela.
// Deploy com --no-verify-jwt (como o vigia-n8n): não recebe nem devolve dado de cliente; chamada a mais só grava mais uma leitura.
// Segredo opcional (Supabase › Edge Functions › Secrets): VULTR_API_KEY — só leitura de conta e instâncias.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const json = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { 'Content-Type': 'application/json' } });
type Leitura = { id: string; nivel: 'ok' | 'atencao' | 'parado' | 'sem_leitura'; texto: string; ms?: number; dado?: Record<string, unknown> };
type Item = { id: string; checagem: string; alvo: string | null };

async function buscar(url: string, timeoutMs: number, headers: Record<string, string> = {}) {
  const t0 = Date.now();
  const ctl = new AbortController();
  const tm = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(url, { signal: ctl.signal, headers: { 'User-Agent': 'niogen-ferramentas-vigia', ...headers }, redirect: 'follow' });
    const txt = await r.text();
    let body: unknown = null;
    try { body = JSON.parse(txt); } catch { /* não é JSON */ }
    return { ok: r.ok, http: r.status, ms: Date.now() - t0, body, erro: r.ok ? null : `HTTP ${r.status}` };
  } catch (e) {
    const erro = ctl.signal.aborted ? `sem resposta em ${Math.round(timeoutMs / 1000)} s` : String((e as Error)?.message || e);
    return { ok: false, http: null as number | null, ms: Date.now() - t0, body: null as unknown, erro };
  } finally {
    clearTimeout(tm);
  }
}

const usd = (n: unknown) => `US$ ${Number(n || 0).toFixed(2).replace('.', ',')}`;

async function conferir(it: Item, tmo: number, vultr: () => Promise<Record<string, unknown> | string>): Promise<Leitura> {
  const id = it.id;
  switch (it.checagem) {
    case 'http': {
      const r = await buscar(String(it.alvo), tmo);
      return { id, nivel: r.ok ? 'ok' : 'parado', ms: r.ms, texto: r.ok ? `no ar · ${r.ms} ms` : `não abre: ${r.erro}` };
    }
    case 'chatwoot_api': {
      const r = await buscar(String(it.alvo || 'https://app.chatwoot.com/api'), tmo);
      const b = (r.body || {}) as Record<string, unknown>;
      if (!r.ok) return { id, nivel: 'parado', ms: r.ms, texto: `API não responde: ${r.erro}` };
      const bom = b.queue_services === 'ok' && b.data_services === 'ok';
      return { id, nivel: bom ? 'ok' : 'atencao', ms: r.ms, dado: { versao: b.version },
        texto: bom ? `no ar · ${r.ms} ms · versão ${b.version ?? '?'}` : `fila ${b.queue_services ?? '?'} · dados ${b.data_services ?? '?'}` };
    }
    case 'statuspage': {
      const r = await buscar(String(it.alvo), tmo);
      const st = ((r.body || {}) as Record<string, any>).status || {};
      if (!r.ok || !st.indicator) return { id, nivel: 'sem_leitura', ms: r.ms, texto: `página de status não leu (${r.erro ?? 'sem indicador'})` };
      const ind = String(st.indicator);
      // incidente no fornecedor não prova que o NOSSO uso caiu: vira atenção, nunca "parado"
      // "minor" (degradação parcial) é frequente nos grandes e quase nunca nos atinge: fica verde, com o aviso no texto
      return { id, nivel: ind === 'none' || ind === 'minor' ? 'ok' : 'atencao', ms: r.ms, dado: { indicador: ind },
        texto: ind === 'none' ? 'fornecedor sem incidente' : `${ind === 'minor' ? 'aviso do fornecedor' : 'incidente no fornecedor'}: ${st.description ?? ind}` };
    }
    case 'rdap': {
      const r = await buscar(`https://rdap.registro.br/domain/${encodeURIComponent(String(it.alvo))}`, tmo);
      const ev = (((r.body || {}) as Record<string, any>).events || []) as Array<Record<string, string>>;
      const exp = ev.find((e) => e.eventAction === 'expiration')?.eventDate;
      if (!r.ok || !exp) return { id, nivel: 'sem_leitura', ms: r.ms, texto: `Registro.br não leu (${r.erro ?? 'sem data de expiração'})` };
      const dia = exp.slice(0, 10);
      return { id, nivel: 'ok', ms: r.ms, dado: { expira: dia }, texto: `registrado até ${dia.split('-').reverse().join('/')}` };
    }
    case 'vultr_conta': {
      const v = await vultr();
      if (typeof v === 'string') return { id, nivel: 'sem_leitura', texto: v };
      const a = (v.account || {}) as Record<string, number>;
      // Vultr: balance negativo = crédito pré-pago; positivo = valor devido
      const saldo = Number(a.balance || 0), pend = Number(a.pending_charges || 0);
      const credito = saldo < 0 ? -saldo : 0;
      const devendo = saldo > 0;
      const curto = !devendo && pend > credito;
      return {
        id, nivel: devendo ? 'parado' : curto ? 'atencao' : 'ok',
        dado: { balance: saldo, pending_charges: pend, last_payment_date: (v.account as any)?.last_payment_date, last_payment_amount: (v.account as any)?.last_payment_amount, instancias: v.instancias },
        texto: devendo ? `conta devendo ${usd(saldo)} — pagar já (a VPS cai)`
          : `crédito ${usd(credito)} · a cobrar no mês ${usd(pend)}${curto ? ' — o crédito não cobre' : ''}`,
      };
    }
    case 'vultr_instancia': {
      const v = await vultr();
      if (typeof v === 'string') return { id, nivel: 'sem_leitura', texto: v };
      const ins = ((v.instancias || []) as Array<Record<string, string>>).find((i) => i.main_ip === it.alvo);
      if (!ins) return { id, nivel: 'atencao', texto: `nenhuma VPS com o IP ${it.alvo} na conta` };
      const bom = ins.status === 'active' && ins.power_status === 'running';
      return { id, nivel: bom ? 'ok' : 'parado', dado: { status: ins.status, power: ins.power_status, server: ins.server_status, plano: ins.plan, regiao: ins.region },
        texto: bom ? `ligada · ${ins.plan ?? ''} · ${ins.region ?? ''}`.trim() : `status ${ins.status} · energia ${ins.power_status}` };
    }
  }
  return { id, nivel: 'sem_leitura', texto: `checagem desconhecida: ${it.checagem}` };
}

Deno.serve(async () => {
  const { data: cfgAll, error } = await sb.rpc('ferramentas_para_vigiar');
  if (error) return json({ erro: error.message }, 500);
  const cfg = (cfgAll?.cfg ?? {}) as Record<string, unknown>;
  if (cfg.ligado === false) return json({ ligado: false });
  const tmo = Number(cfg.timeout_ms) || 10000;
  const itens = (cfgAll?.itens ?? []) as Item[];

  // a API da Vultr é lida uma vez só por rodada (conta + instâncias)
  let vultrCache: Promise<Record<string, unknown> | string> | null = null;
  const vultr = () => (vultrCache ??= (async () => {
    const key = Deno.env.get('VULTR_API_KEY');
    if (!key) return 'falta a chave VULTR_API_KEY (Supabase › Edge Functions › Secrets)';
    const h = { Authorization: `Bearer ${key}` };
    const [c, i] = await Promise.all([buscar('https://api.vultr.com/v2/account', tmo, h), buscar('https://api.vultr.com/v2/instances?per_page=100', tmo, h)]);
    if (!c.ok) return `API da Vultr recusou (${c.erro}) — conferir a chave e o controle de acesso por IP`;
    return { account: (c.body as any)?.account, instancias: (i.body as any)?.instances || [] };
  })());

  const [leituras, cot] = await Promise.all([
    Promise.all(itens.map((it) => conferir(it, tmo, vultr).catch((e) => ({ id: it.id, nivel: 'sem_leitura', texto: String(e) } as Leitura)))),
    buscar(String(cfg.cotacao_url || 'https://economia.awesomeapi.com.br/json/last/USD-BRL'), tmo),
  ]);
  // não guardar a lista inteira de instâncias em cada leitura da conta: só o essencial
  for (const l of leituras) if (l.dado && 'instancias' in l.dado) {
    l.dado.instancias = ((l.dado.instancias || []) as Array<Record<string, string>>).map((i) => ({ ip: i.main_ip, status: i.status, power: i.power_status, rotulo: i.label }));
  }
  // dólar: a fonte da config (AwesomeAPI); se ela não responder daqui, a reserva open.er-api.com
  let bid = Number(((cot.body || {}) as Record<string, any>)?.USDBRL?.bid);
  if (!(bid > 0)) {
    const r2 = await buscar('https://open.er-api.com/v6/latest/USD', tmo);
    bid = Number(((r2.body || {}) as Record<string, any>)?.rates?.BRL);
  }
  const { data: g, error: e2 } = await sb.rpc('ferramentas_registrar', { p_leituras: leituras, p_cotacao: Number.isFinite(bid) && bid > 0 ? bid : null });
  if (e2) return json({ erro: e2.message, leituras }, 500);
  return json({ gravadas: g?.gravadas ?? 0, cotacao: bid || null, niveis: leituras.map((l) => `${l.id}:${l.nivel}`) });
});
