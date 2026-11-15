// NIOGEN | supabase/functions/dfv-consulta/index.ts | 11/11/2026 — Claude Code (docs/Prompt_operador_dfv_cobertura_111126_1520.md)
// rev. 14/11/2026 — Claude Code / Opus 5.5 (docs/Prompt_dfv_api_e_rua_do_portal_141126_1935.md, parte A): API do Power BI primeiro.
// Cobertura (DFV) ao vivo — CONSULTA-SÓ. Qualquer usuário logado do NIOGEN (ou o n8n com a service role) chama; nada é gravado.
// 1. confere que quem chama é usuário do NIOGEN (meu_perfil() com o JWT dele);
// 2. pergunta à API do Power BI (querydata da tabela BASE_HP_F, liberada pelo Rogério/Nio em 14/11): região pela faixa do CEP,
//    chave e modelId em config_regras.dfv_api (gravados pelo CLI, nunca no repo). Uma chamada traz o CEP inteiro, com lat/long.
//    ~0,5 s. Cache de cache_s (10 min) por CEP na memória da função;
// 3. API desligada (dfv_api.ligado = false), sem região ou com erro → OPERADOR DFV na VPS (Chromium no painel "DFV Sudeste"),
//    server-to-server com o Bearer DFV_OP_TOKEN — reserva até 21/11/2026;
// 4. operador sem resposta em DFV_OP_TIMEOUT_MS (padrão 12 s) ou com erro → RPC dfv_consultar (base congelada de JF, nio_hp)
//    com o JWT de quem chamou, marcado { fonte: 'base_congelada' } — a tela nunca fica muda.
// A resposta da API sai no MESMO formato do GET /dfv do operador (dfv/README.md), com fonte 'api' e a região.
// Segredos (Supabase › Edge Functions › Secrets): DFV_OP_URL, DFV_OP_TOKEN. Nada no front, no repo ou no Drive.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const so = (s: unknown) => String(s ?? '').replace(/\D/g, '');

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405);
  const t0 = Date.now();
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
    // 12/11 (0131): o n8n mari_viabilidade chama com a service role (a chave do pedido segue adiante) — consulta-só, igual à tela.
    const chave = req.headers.get('apikey') || anon;
    const quem = createClient(url, chave, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const [{ data: perfil, error: ePerfil }, { data: servico }] = await Promise.all([quem.rpc('meu_perfil'), quem.rpc('sou_service_role')]);
    if (servico !== true && (ePerfil || !perfil)) return json({ error: 'Entre no NIOGEN para consultar.' }, 403);

    const b = await req.json().catch(() => ({}));
    const cep = so(b.cep);
    if (cep.length !== 8) return json({ error: 'Informe o CEP com 8 dígitos.' }, 400);
    const numero = String(b.numero ?? '').trim().slice(0, 20);
    const complemento = String(b.complemento ?? '').trim().slice(0, 60);
    const uf = String(b.uf ?? '').trim().toUpperCase().slice(0, 2);
    const municipio = String(b.municipio ?? '').trim().toUpperCase().slice(0, 80);
    if (b.forcar_base === true) return await congelada(quem, cep, numero, complemento, 'pedido da tela', t0);

    // ---- 1º: API do Power BI
    let motivoApi = '';
    const { data: cfgRow } = await quem.from('config_regras').select('valor').eq('chave', 'dfv_api').maybeSingle();
    const cfg = (cfgRow?.valor ?? null) as CfgApi | null;
    if (cfg?.ligado && b.forcar_operador !== true) {
      try {
        const r = await consultarApi(cfg, { cep, numero, complemento, uf, municipio });
        return json({ ...r, ms_total: Date.now() - t0 });
      } catch (e) {
        motivoApi = `API: ${String((e as Error)?.message ?? e).slice(0, 160)}`;
      }
    } else {
      motivoApi = cfg ? 'API desligada' : 'API sem config';
    }

    // ---- 2º: operador da VPS (reserva)
    const opUrl = (Deno.env.get('DFV_OP_URL') ?? '').replace(/\/+$/, '');
    const opTok = Deno.env.get('DFV_OP_TOKEN') ?? '';
    const limite = Number(Deno.env.get('DFV_OP_TIMEOUT_MS') ?? '12000');
    if (!opUrl || !opTok) return await congelada(quem, cep, numero, complemento, `${motivoApi} · operador não configurado`, t0);

    const qs = new URLSearchParams({ cep, numero, complemento });
    if (uf) qs.set('uf', uf);
    if (municipio) qs.set('municipio', municipio);
    let motivo = '';
    try {
      const r = await fetch(`${opUrl}/dfv?${qs}`, {
        headers: { Authorization: `Bearer ${opTok}` }, signal: AbortSignal.timeout(limite),
      });
      const d = await r.json().catch(() => null);
      if (r.ok && d?.ok) {
        delete d.ok;
        return json({ ...d, motivo_api: motivoApi || undefined, ms_total: Date.now() - t0 });
      }
      motivo = r.ok && !d ? 'a rota do operador não respondeu como operador (proxy)'
        : `operador respondeu ${r.status}${d?.erro ? ` (${d.erro})` : ''}`;
    } catch (e) {
      motivo = (e as Error)?.name === 'TimeoutError' ? `operador sem resposta em ${Math.round(limite / 1000)} s` : 'operador fora do ar';
    }
    return await congelada(quem, cep, numero, complemento, `${motivoApi} · ${motivo}`, t0);
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});

// Fallback: a mesma RPC de antes (nio_hp, foto de JF), com o JWT de quem chamou. Não grava nada.
// deno-lint-ignore no-explicit-any
async function congelada(quem: any, cep: string, numero: string, complemento: string, motivo: string, t0: number) {
  const { data, error } = await quem.rpc('dfv_consultar', { p_cep: cep, p_numero: numero, p_complemento: complemento || null });
  if (error) return json({ error: `Painel ao vivo indisponível (${motivo}) e base congelada com erro: ${error.message}` }, 502);
  const r = (data || [])[0] || null;
  return json({ fonte: 'base_congelada', motivo, particao: r?.particao ?? null, rpc: r, ms_total: Date.now() - t0 });
}

// ====================================================================== API do Power BI
type Regiao = { cod: string; ceps: [string, string][]; chave: string; model: number };
type CfgApi = { ligado: boolean; cluster: string; entidade?: string; timeout_ms?: number; cache_s?: number; janela?: number; regioes: Regiao[] };
type Entrada = { cep: string; numero: string; complemento: string; uf: string; municipio: string };
// deno-lint-ignore no-explicit-any
type Linha = Record<string, any>;

// Colunas da BASE_HP_F (testadas em 14/11 no modelo Sudeste). HPS/HCS não existem na tabela: HP_TOT/HC_TOT no lugar.
const COLS_COMPLETAS = ['UF', 'MUNICIPIO', 'CODIGO_LOGRADOURO', 'CODIGO_CDO', 'CLASSIFICACAO', 'CELULA', 'BAIRRO', 'LOGRADOURO',
  'NO_FACHADA', 'COMPLEMENTO1', 'COMPLEMENTO2', 'COMPLEMENTO3', 'CEP', 'HP_TOT', 'HP_LIVRE', 'HC_TOT', 'VIABILIDADE_ATUAL',
  'FLAG_GROSS_6M_CEL', 'ds_faixa_aprovacao_credito_total', 'F_HP_NOVO', 'TIPO_EDIFICACAO', 'LATITUDE', 'LONGITUDE', 'dt_dfv_particao'];
// As 11 do documento do Rogério — reserva se algum modelo recusar uma coluna (uma coluna inválida derruba a consulta inteira).
const COLS_BASE = ['CEP', 'NO_FACHADA', 'COMPLEMENTO1', 'COMPLEMENTO2', 'COMPLEMENTO3', 'LOGRADOURO', 'BAIRRO', 'MUNICIPIO', 'UF',
  'VIABILIDADE_ATUAL', 'CODIGO_CDO'];
const NOME: Record<string, string> = {
  UF: 'uf', MUNICIPIO: 'municipio', CODIGO_LOGRADOURO: 'cd_logradouro', CODIGO_CDO: 'cd_cdo', CLASSIFICACAO: 'classificacao',
  CELULA: 'celula', BAIRRO: 'bairro', LOGRADOURO: 'logradouro', NO_FACHADA: 'numero', COMPLEMENTO1: 'complemento',
  COMPLEMENTO2: 'complemento2', COMPLEMENTO3: 'complemento3', CEP: 'cep', HP_TOT: 'hps', HP_LIVRE: 'hp_livre', HC_TOT: 'hcs',
  VIABILIDADE_ATUAL: 'viabilidade', FLAG_GROSS_6M_CEL: 'flag_gross_6m', ds_faixa_aprovacao_credito_total: 'faixa_credito',
  F_HP_NOVO: 'flag_hp_novo', TIPO_EDIFICACAO: 'tipo_edificacao', LATITUDE: 'lat', LONGITUDE: 'lon', dt_dfv_particao: 'particao_ms',
};

const CACHE = new Map<string, { em: number; linhas: Linha[]; colunas: string; regiao: string }>();
const RECUSA_COMPLETA = new Set<string>();   // regiões cujo modelo recusou a lista completa (nesta instância)

function regiaoDoCep(cfg: CfgApi, cep: string): Regiao | null {
  const p = cep.slice(0, 5);
  return (cfg.regioes || []).find((r) => (r.ceps || []).some(([a, b]) => p >= a && p <= b)) ?? null;
}

function payload(cfg: CfgApi, reg: Regiao, cep: string, cols: string[]) {
  const ent = cfg.entidade || 'BASE_HP_F';
  const col = (c: string) => ({ Column: { Expression: { SourceRef: { Source: 'b' } }, Property: c } });
  return {
    version: '1.0.0',
    queries: [{ Query: { Commands: [{ SemanticQueryDataShapeCommand: {
      Query: {
        Version: 2, From: [{ Name: 'b', Entity: ent, Type: 0 }],
        Select: cols.map((c) => ({ ...col(c), Name: `${ent}.${c}` })),
        Where: [{ Condition: { Comparison: { ComparisonKind: 0, Left: col('CEP'), Right: { Literal: { Value: `'${cep}'` } } } } }],
      },
      Binding: { Primary: { Groupings: [{ Projections: cols.map((_, i) => i) }] },
        DataReduction: { DataVolume: 4, Primary: { Window: { Count: cfg.janela || 5000 } } }, Version: 1 },
    } }] } }],
    cancelQueries: [], modelId: reg.model,
  };
}

async function pedir(cfg: CfgApi, reg: Regiao, cep: string, cols: string[]): Promise<Linha[]> {
  const r = await fetch(`${cfg.cluster.replace(/\/+$/, '')}/public/reports/querydata?synchronous=true`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json;charset=UTF-8', Accept: 'application/json', 'X-PowerBI-ResourceKey': reg.chave,
      Origin: 'https://app.powerbi.com', Referer: 'https://app.powerbi.com/',
      ActivityId: crypto.randomUUID(), RequestId: crypto.randomUUID(),
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    },
    body: JSON.stringify(payload(cfg, reg, cep, cols)),
    signal: AbortSignal.timeout(cfg.timeout_ms || 18000),
  });
  if (!r.ok) throw new Error(`Power BI respondeu ${r.status}`);
  const d = await r.json();
  const data = d?.results?.[0]?.result?.data;
  const erro = JSON.stringify(data?.dsr?.DataShapes ?? '').match(/"code":"([^"]+)"/);
  if (erro) throw new RecusaColuna(erro[1]);
  if (!data?.dsr?.DS) throw new Error('Power BI sem dados na resposta');
  return decodificar(data);
}
class RecusaColuna extends Error {}

// Resposta querydata → linhas {coluna: valor}. Formato DSR v2 (comprimido: S / C / R / Ø / ValueDicts / M) — porte do operador.py.
// deno-lint-ignore no-explicit-any
function decodificar(data: any): Linha[] {
  const nome: Record<string, string> = {};
  for (const s of data.descriptor?.Select ?? []) nome[s.Value] = s.Name;
  const ds = data.dsr.DS[0];
  const dicts = ds.ValueDicts ?? {};
  const linhas: Linha[] = [];
  // deno-lint-ignore no-explicit-any
  const dm = (rows: any[], pai: Linha) => {
    // deno-lint-ignore no-explicit-any
    let esquema: any[] | null = null;
    // deno-lint-ignore no-explicit-any
    let ant: any[] = [];
    for (const r of rows) {
      if (r.S) { esquema = r.S; ant = new Array(r.S.length).fill(null); }
      if (!esquema) continue;
      const rep = r.R ?? 0, nul = r['Ø'] ?? 0;
      const c = [...(r.C ?? [])];
      // deno-lint-ignore no-explicit-any
      const atual: any[] = esquema.map((col, i) => {
        // deno-lint-ignore no-explicit-any
        let v: any;
        if (col.N in r) v = r[col.N];
        else if ((rep >> i) & 1) v = ant[i];
        else if ((nul >> i) & 1) v = null;
        else v = c.length ? c.shift() : null;
        if (col.DN && typeof v === 'number') v = dicts[col.DN][v];
        return v;
      });
      ant = atual;
      const vals: Linha = { ...pai };
      esquema.forEach((col, i) => { vals[nome[col.N] ?? col.N] = atual[i]; });
      if (r.M) {
        // deno-lint-ignore no-explicit-any
        for (const filho of r.M) for (const sub of Object.values(filho)) dm(sub as any[], vals);
      } else linhas.push(vals);
    }
  };
  for (const ph of ds.PH ?? []) for (const rows of Object.values(ph)) dm(rows as unknown[], {});
  return linhas;
}

const norm = (s: unknown) => String(s ?? '').normalize('NFKD').replace(/[̀-ͯ]/g, '').toUpperCase().replace(/[^A-Z0-9]/g, '');
const numInt = (s: unknown) => { const m = String(s ?? '').match(/^\d+/); return m ? Number(m[0]) : null; };
const viavel = (v: unknown) => /^VIAV/.test(norm(v));

async function consultarApi(cfg: CfgApi, e: Entrada) {
  const t0 = Date.now();
  const reg = regiaoDoCep(cfg, e.cep);
  if (!reg) throw new Error(`CEP ${e.cep.slice(0, 5)}… fora das regiões da config`);
  const ent = cfg.entidade || 'BASE_HP_F';
  let hit = CACHE.get(e.cep);
  let metodo = 'cache';
  if (!hit || Date.now() - hit.em > (cfg.cache_s ?? 600) * 1000) {
    let linhas: Linha[], colunas = 'completas';
    if (RECUSA_COMPLETA.has(reg.cod)) {
      linhas = await pedir(cfg, reg, e.cep, COLS_BASE); colunas = 'base';
    } else {
      try { linhas = await pedir(cfg, reg, e.cep, COLS_COMPLETAS); } catch (er) {
        if (!(er instanceof RecusaColuna)) throw er;
        RECUSA_COMPLETA.add(reg.cod);
        linhas = await pedir(cfg, reg, e.cep, COLS_BASE); colunas = 'base';
      }
    }
    hit = { em: Date.now(), linhas, colunas, regiao: reg.cod };
    CACHE.set(e.cep, hit);
    if (CACHE.size > 500) CACHE.delete(CACHE.keys().next().value!);
    metodo = 'api';
  }
  // linha da API → fachada no formato do operador
  const todas = hit.linhas.map((l) => {
    const f: Linha = {};
    for (const [k, v] of Object.entries(l)) { const c = k.startsWith(`${ent}.`) ? k.slice(ent.length + 1) : k; if (NOME[c]) f[NOME[c]] = v; }
    return f;
  }).filter((f) => f.numero || f.logradouro);
  const particaoMs = Math.max(0, ...todas.map((f) => Number(f.particao_ms) || 0)) || null;
  todas.forEach((f) => { delete f.particao_ms; if (!('lat' in f)) { f.lat = null; f.lon = null; } });
  // A tabela repete a mesma fachada quando muda outra coluna (CDO, célula, lat/long): uma linha por rua · número · complementos.
  const vistas = new Set<string>();
  const fach = todas.filter((f) => viavel(f.viabilidade)).filter((f) => {
    const k = [f.logradouro, f.numero, f.complemento, f.complemento2, f.complemento3].map(norm).join('|');
    if (vistas.has(k)) return false;
    vistas.add(k);
    return true;
  });
  fach.sort((a, b) => norm(a.logradouro).localeCompare(norm(b.logradouro)) || (numInt(a.numero) ?? 0) - (numInt(b.numero) ?? 0)
    || String(a.complemento ?? '').localeCompare(String(b.complemento ?? '')));
  return montar(e, fach, particaoMs, metodo, Date.now() - t0, hit.regiao, hit.colunas);
}

// Mesmo formato e mesmas regras do montar() do operador.py (casamento de número/complemento e regra dos 200 m).
function montar(e: Entrada, fach: Linha[], particaoMs: number | null, metodo: string, ms: number, regiao: string, colunas: string) {
  const numero = e.numero.trim();
  const comp = norm(e.complemento);
  let match = 'sem_numero', viab: string | null = null;
  let achadas: Linha[] = [];
  if (numero) {
    achadas = fach.filter((f) => String(f.numero ?? '').trim().toUpperCase() === numero.toUpperCase());
    if (comp && achadas.length) {
      const exatas = achadas.filter((f) => [f.complemento, f.complemento2, f.complemento3].some((x) => norm(x) === comp));
      if (exatas.length) achadas = exatas;
    }
    match = achadas.length ? 'exato' : 'nao_encontrado';
    viab = achadas.length ? 'viavel' : 'nao_encontrado';
  } else viab = fach.length ? 'rua_viavel' : 'nao_encontrado';
  const ref = achadas[0] ?? fach[0] ?? null;

  // deno-lint-ignore no-explicit-any
  let regra: any = { status: 'nao_avaliada_v1', nota: 'v1: sem lat/long do endereço do cliente — conferir os 200 m no mapa do painel.' };
  if (match === 'exato') regra = { status: 'dentro', nota: 'A própria fachada está na base de viáveis.' };
  else if (match === 'nao_encontrado' && fach.length) {
    const alvo = numInt(numero);
    const viz = fach.filter((f) => numInt(f.numero) !== null)
      .sort((a, b) => (alvo !== null ? Math.abs(numInt(a.numero)! - alvo) - Math.abs(numInt(b.numero)! - alvo) : 0));
    const perto = viz[0] ?? null;
    regra.nota = 'Há fachadas viáveis neste CEP — conferir os 200 m no mapa do painel'
      + (perto ? ` (a mais próxima pela numeração: nº ${perto.numero}, ${perto.logradouro ?? ''}).` : '.');
    regra.vizinha_mais_proxima = perto ? { numero: perto.numero, logradouro: perto.logradouro, lat: perto.lat, lon: perto.lon } : null;
  } else if (!fach.length) regra = { status: 'indefinido', nota: 'Nenhuma fachada viável neste CEP no painel — conferir CEP/rua no portal.' };

  const d = particaoMs ? new Date(particaoMs) : null;
  const atual = d ? `${String(d.getUTCDate()).padStart(2, '0')}/${String(d.getUTCMonth() + 1).padStart(2, '0')}/${d.getUTCFullYear()}` : null;
  return {
    consultado_em: new Date().toISOString(),
    atualizado_painel: atual,
    fonte: 'api',
    metodo,
    regiao,
    colunas,
    ms,
    entrada: { uf: e.uf || null, municipio: e.municipio || null, cep: e.cep, numero: e.numero || null, complemento: e.complemento || null },
    match,
    viabilidade: viab,
    faixa_credito_bairro: ref?.faixa_credito ?? null,
    bairro: ref?.bairro ?? null,
    logradouro: ref?.logradouro ?? null,
    celula: ref?.celula ?? null,
    classificacao: ref?.classificacao ?? null,
    fachada: achadas[0] ?? null,
    unidades: achadas.length > 1 ? achadas : [],
    fachadas_no_cep: fach.slice(0, 300),
    total_fachadas_no_cep: fach.length,
    regra_200m: regra,
  };
}
