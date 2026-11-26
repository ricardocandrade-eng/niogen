// NIOGEN | supabase/functions/credito-consulta/index.ts | 11/11/2026 — Claude Code (docs/Prompt_operador_credito_consulta_111126_1650.md)
// Consulta de crédito na Nio — CONSULTA-SÓ, ASSÍNCRONA. Só admin e backoffice (403 para os demais).
//   {acao: 'iniciar', cpf, endereco?, contato?, autorizado} → exige autorizado === true e CPF com dígito válido →
//        POST {CREDITO_OP_URL}/credito (X-Portal-Secret) → {job_id, posicao_fila, estado} (cache 24 h → já vem pronto)
//        26/11: {acao: 'iniciar', cpf, autorizado, ficticio: true} → "dados fictícios": endereço e contato do rodízio do operador.
//   {acao: 'status', job_id}                               → GET {CREDITO_OP_URL}/credito/{job_id}
//   14/11: endereco.logradouro_esperado (rua confirmada pelo cliente ou a do ViaCEP) vai ao operador, que confere a rua resolvida
//        pelo portal antes de aceitar (resultado novo rua_divergente). Ver ruaEsperada() no fim.
//   {acao: 'viabilidade', endereco}                       → POST {CREDITO_OP_URL}/credito/viabilidade — SÓ Etapas 0–2 do
//        portal, sem CPF/contato (11/11 ~21h, docs/Prompt_consulta_unificada_111126_2045.md). Qualquer usuário logado.
//   {acao: 'print', job_id}                                → GET {CREDITO_OP_URL}/credito/print/{job_id} — print da tela do portal
//        quando a viabilidade NÃO saiu (11/11 ~22h30, pedido do Ricardo). Só Etapas 0–2, sem CPF; fica 7 dias na VPS. Só admin/backoffice.
//   {acao: 'os', venda_id}                                  → 13/11 (etapa 3, "Consultar OS agora"): lê o andamento da OS de UMA venda
//        registrada. O CPF e o nº da OS saem do banco (nunca do navegador) → POST {CREDITO_OP_URL}/credito/os. Só admin/backoffice.
//   {acao: 'os_status', job_id, venda_id}                   → GET /credito/{job_id}; quando a leitura chega, grava com
//        os_registrar_leitura (origem operador) e devolve {estado, resultado, leitura, registro}. Leitura igual não regrava.
//   {acao: 'bio', venda_id | conversa_id}                                → 14/11 (0194, degrau Biometria da ficha): manda o robô do GED360 (n8n,
//        mesmo login e mesmo Relatório Detalhado em CSV do agendamento de 15 min) ler AGORA e devolve a biometria desta venda
//        (protocolo, resultado, datas — nunca o CPF). Secret N8N_GED360_AGORA_URL (caminho secreto do webhook). Só admin/backoffice.
//   22/11 (Ricardo: "Libera a OS e o GED360 com dados digitados" — Consulta central, dados novos):
//   {acao: 'os', cpf, os, criada_em?}                       → a mesma leitura da Consulta OS com CPF/CNPJ e nº da OS DIGITADOS (sem venda
//        no NIOGEN). {acao: 'os_status', job_id, os} acompanha. Só lê: nada é gravado (sem os_registrar_leitura). Só admin/backoffice.
//   {acao: 'bio', cpf}                                      → o mesmo robô do GED360, filtrando a biometria pelo CPF/CNPJ DIGITADO. Só lê.
// A consulta leva ~2 min no portal: a tela faz polling; esta função nunca segura a conexão aberta.
// Segredos (Supabase › Edge Functions › Secrets): CREDITO_OP_URL, NIO_PORTAL_SERVICO_SECRET. Nada no front nem no repo.
// Crédito e viabilidade não gravam nada aqui. A leitura da OS grava só o andamento (sem dado pessoal). Log: usuário, ação,
// resultado, ms — nunca o CPF.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const so = (s: unknown) => String(s ?? '').replace(/\D/g, '');

function cpfValido(c: string) {
  if (c.length !== 11 || /^(\d)\1{10}$/.test(c)) return false;
  for (const n of [9, 10]) {
    let soma = 0;
    for (let i = 0; i < n; i++) soma += Number(c[i]) * (n + 1 - i);
    if (((soma * 10) % 11) % 10 !== Number(c[n])) return false;
  }
  return true;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405);
  const t0 = Date.now();
  let usuario = '?';
  let acao = '?';
  const log = (resultado: string) => console.log(`credito-consulta · ${usuario} · ${acao} · ${resultado} · ${Date.now() - t0} ms`);
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
    // 12/11 (0131): a chave do pedido segue adiante — com a do n8n (service role), o banco responde sou_service_role() = true.
    const chave = req.headers.get('apikey') || anon;
    const quem = createClient(url, chave, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const [{ data: perfilUsuario, error: ePerfil }, { data: u }, { data: servico }] =
      await Promise.all([quem.rpc('meu_perfil'), quem.auth.getUser(), quem.rpc('sou_service_role')]);
    // O n8n só pode viabilidade, duplicidade, status e — 0138 (regra 5 revista, 12/11) — o crédito da Mari, que ele só pede
    // depois de a autorização do titular estar gravada na conversa (mari_credito_pendentes). Print nunca.
    const perfil = servico === true ? 'n8n' : perfilUsuario;
    usuario = servico === true ? 'n8n' : (u?.user?.id?.slice(0, 8) ?? '?');
    if (servico !== true && (ePerfil || !perfil)) { log('403 sem login'); return json({ error: 'Entre no NIOGEN para consultar.' }, 403); }
    const b = await req.json().catch(() => ({}));
    acao = String(b.acao ?? '');
    if (servico === true && !['viabilidade', 'status', 'duplicidade', 'iniciar'].includes(acao)) { log('403 n8n so viabilidade'); return json({ error: 'Só viabilidade.' }, 403); }
    // Viabilidade (sem CPF) e status (job id de 32 hex) valem para qualquer logado; o crédito do CPF só admin/backoffice.
    if (['iniciar', 'print', 'duplicidade', 'os', 'os_status', 'bio'].includes(acao) && servico !== true && !['admin', 'backoffice'].includes(String(perfil))) { log(`403 perfil ${perfil}`); return json({ error: 'A consulta de crédito é só do backoffice.' }, 403); }
    if (acao === 'bio') {
      // 15/11 (Ricardo): também para o lead SEM venda — {acao:'bio', conversa_id}: lê pelo CPF que a conversa guardou.
      const vendaId = String(b.venda_id ?? '');
      const convId = String(b.conversa_id ?? '');
      const docDig = so(b.cpf);   // 22/11: CPF/CNPJ digitado na Consulta central (sem venda nem conversa)
      const porDoc = !vendaId && !convId && (cpfValido(docDig) || docDig.length === 14);
      if (!porDoc && !/^[0-9a-f-]{36}$/.test(vendaId) && !/^[0-9a-f-]{36}$/.test(convId)) return json({ error: b.cpf ? 'CPF inválido (confira os dígitos).' : 'venda inválida.' }, 400);
      const gancho = Deno.env.get('N8N_GED360_AGORA_URL') ?? '';
      if (!gancho) { log('503 bio nao_instalado'); return json({ error: 'Leitura na hora do GED360 ainda não instalada.', nao_instalado: true }, 503); }
      const adm = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
      let v: { id: string | null; cliente_cpf_cnpj: string | null } | null = null;
      if (porDoc) {
        v = { id: null, cliente_cpf_cnpj: docDig };
      } else if (vendaId) {
        const { data } = await adm.from('vendas').select('id, cliente_cpf_cnpj').eq('id', vendaId).maybeSingle();
        v = data;
      } else {
        const { data: c } = await adm.from('mari_conversas').select('id, venda_id, dados').eq('id', convId).maybeSingle();
        if (c) v = { id: c.venda_id ?? null, cliente_cpf_cnpj: String((c.dados ?? {}).cpf ?? '') };
        if (v && so(v.cliente_cpf_cnpj).length !== 11 && !v.id) { log('400 conversa sem cpf'); return json({ error: 'Esta conversa ainda não tem CPF.' }, 400); }
      }
      if (!v) { log('404 venda'); return json({ error: 'Venda não encontrada.' }, 404); }
      const vid = v.id ?? '00000000-0000-0000-0000-000000000000';
      let rodada: Record<string, unknown> | null = null;
      let erro: string | null = null;
      try {
        const rr = await fetch(gancho, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(110000) });
        rodada = await rr.json().catch(() => null);
        if (!rr.ok) erro = `o robô do GED360 respondeu ${rr.status}`;
        else if (rodada && rodada.ok === false) erro = `GED360: ${String(rodada.erro ?? 'leitura falhou')}`.slice(0, 200);
      } catch (e) {
        erro = (e as Error)?.name === 'TimeoutError' ? 'O GED360 demorou demais. Tente de novo em 1 minuto.' : 'Robô do GED360 fora do ar.';
      }
      const doc = so(v.cliente_cpf_cnpj);
      let qb = adm.from('nio_biometria').select('protocolo, resultado, data_envio, data_conferencia, ultima_leitura, alerta, venda_id');
      qb = doc.length >= 11 ? qb.or(`venda_id.eq.${vid},cpf_cnpj.eq.${doc}`) : qb.eq('venda_id', vid);
      const { data: bs } = await qb.order('data_envio', { ascending: false, nullsFirst: false }).limit(3);
      const { data: vv } = v.id ? await adm.from('vendas').select('biometria_status, biometria_validada_em').eq('id', v.id).maybeSingle() : { data: null };
      log(`bio ${erro ? 'erro' : 'ok'} ${(bs ?? []).length}`);
      return json({ estado: erro ? 'erro' : 'pronto', erro, linhas: rodada?.linhas ?? null, mudancas: rodada?.mudancas ?? null,
        biometrias: (bs ?? []).map((x) => ({ protocolo: x.protocolo, resultado: x.resultado, data_envio: x.data_envio,
          data_conferencia: x.data_conferencia, lido_em: x.ultima_leitura, alerta: x.alerta, casada: !!v.id && x.venda_id === v.id })),
        venda: vv ?? null });
    }
    const opUrl = (Deno.env.get('CREDITO_OP_URL') ?? '').replace(/\/+$/, '');
    const segredo = Deno.env.get('NIO_PORTAL_SERVICO_SECRET') ?? '';
    if (!opUrl || !segredo) { log('503 nao_instalado'); return json({ error: 'Operador de crédito ainda não instalado.', nao_instalado: true }, 503); }
    const hdr = { 'X-Portal-Secret': segredo, 'Content-Type': 'application/json' };

    let r: Response;
    if ((acao === 'os' || acao === 'os_status') && !b.venda_id && b.os) {
      // 22/11 (Ricardo: "Libera a OS e o GED360 com dados digitados"): CPF/CNPJ e nº da OS digitados na Consulta central. Mesma
      // leitura do operador (só "Filtros"/"Filtrar"); NÃO grava nada — a OS pode nem ser de venda do NIOGEN.
      const num = so(b.os);
      if (num.length !== 8) return json({ error: 'Número da OS com 8 dígitos.' }, 400);
      if (acao === 'os') {
        const doc = so(b.cpf);
        if (!(doc.length === 14 || cpfValido(doc))) { log('400 doc'); return json({ error: 'CPF/CNPJ inválido (confira os dígitos).' }, 400); }
        const criada = /^\d{4}-\d{2}-\d{2}$/.test(String(b.criada_em ?? '')) ? String(b.criada_em) : '';
        r = await fetch(`${opUrl}/credito/os`, { method: 'POST', headers: hdr,
          body: JSON.stringify({ cpf: doc, os: num, criada_em: criada, origem: `niogen:${perfil}:digitado` }), signal: AbortSignal.timeout(15000) });
      } else {
        const id = String(b.job_id ?? '');
        if (!/^[0-9a-f]{32}$/.test(id)) return json({ error: 'job inválido.' }, 400);
        r = await fetch(`${opUrl}/credito/${id}`, { headers: hdr, signal: AbortSignal.timeout(10000) });
      }
      const d = await r.json().catch(() => null);
      if (!d) { log(`502 operador ${r.status} sem json`); return json({ error: `Operador respondeu ${r.status} sem JSON.` }, 502); }
      if (!r.ok || d.ok === false) {
        log(`${r.status} ${d.erro ?? ''}`);
        return json({ error: r.status === 429 ? 'O operador está ocupado com outra consulta. Tente de novo em 1 minuto.' : (d.erro ?? `Operador respondeu ${r.status}.`) },
          r.status === 429 ? 429 : r.status === 400 ? 400 : 502);
      }
      if (d.modo !== 'os') { log('400 job de outro tipo'); return json({ error: 'job inválido.' }, 400); }
      log(`digitado ${d.estado}${d.resultado ? ` ${d.resultado}` : ''}${d.cache ? ' cache' : ''}`);
      return json({ job_id: d.job_id, estado: d.estado, resultado: d.resultado ?? null, motivo: d.motivo ?? null,
        leitura: d.leitura ?? null, consultado_em: d.consultado_em ?? null, cache: d.cache === true, digitado: true });
    }
    if (acao === 'os' || acao === 'os_status') {
      // 13/11: leitura de acompanhamento de UMA OS. Tudo que identifica o cliente sai do banco, pela chave de serviço.
      const vendaId = String(b.venda_id ?? '');
      if (!/^[0-9a-f-]{36}$/.test(vendaId)) return json({ error: 'venda inválida.' }, 400);
      const adm = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
      const { data: v, error: eV } = await adm.from('vendas')
        .select('cliente_cpf_cnpj, nio_os, nio_pedido, nio_os_em, nio_pedido_em, vendido_em, criado_em').eq('id', vendaId).maybeSingle();
      if (eV || !v) { log('404 venda'); return json({ error: 'Venda não encontrada.' }, 404); }
      const doc = so(v.cliente_cpf_cnpj);
      const num = so(String(v.nio_os ?? '').trim() || v.nio_pedido);
      if (num.length !== 8) { log('400 sem os'); return json({ error: 'Esta venda ainda não tem o nº da OS (8 dígitos).' }, 400); }
      if (!(doc.length === 14 || cpfValido(doc))) { log('400 sem cpf'); return json({ error: 'Esta venda está sem CPF válido — a Nio só pesquisa a OS com o CPF.' }, 400); }
      if (acao === 'os') {
        const criada = String(v.nio_os_em ?? v.nio_pedido_em ?? v.vendido_em ?? v.criado_em ?? '').slice(0, 10);
        r = await fetch(`${opUrl}/credito/os`, { method: 'POST', headers: hdr,
          body: JSON.stringify({ cpf: doc, os: num, criada_em: criada, origem: `niogen:${perfil}` }), signal: AbortSignal.timeout(15000) });
      } else {
        const id = String(b.job_id ?? '');
        if (!/^[0-9a-f]{32}$/.test(id)) return json({ error: 'job inválido.' }, 400);
        r = await fetch(`${opUrl}/credito/${id}`, { headers: hdr, signal: AbortSignal.timeout(10000) });
      }
      const d = await r.json().catch(() => null);
      if (!d) { log(`502 operador ${r.status} sem json`); return json({ error: `Operador respondeu ${r.status} sem JSON.` }, 502); }
      if (!r.ok || d.ok === false) {
        log(`${r.status} ${d.erro ?? ''}`);
        return json({ error: r.status === 429 ? 'O operador está ocupado com outra consulta. Tente de novo em 1 minuto.' : (d.erro ?? `Operador respondeu ${r.status}.`) },
          r.status === 429 ? 429 : r.status === 400 ? 400 : 502);
      }
      if (d.modo !== 'os') { log('400 job de outro tipo'); return json({ error: 'job inválido.' }, 400); }
      const fora: Record<string, unknown> = { job_id: d.job_id, estado: d.estado, resultado: d.resultado ?? null, motivo: d.motivo ?? null,
        leitura: d.leitura ?? null, consultado_em: d.consultado_em ?? null, cache: d.cache === true };
      if (d.estado === 'pronto' && d.resultado === 'lida' && d.leitura) {
        const { data: reg, error: eR } = await adm.rpc('os_registrar_leitura',
          { p_pedido: num, p_origem: 'operador', p_dados: d.leitura, p_referencia_em: d.consultado_em ?? null });
        fora.registro = eR ? { ok: false, erro: 'A leitura veio, mas não consegui gravar no NIOGEN.' } : reg;
      }
      log(`${d.estado}${d.resultado ? ` ${d.resultado}` : ''}${d.cache ? ' cache' : ''}`);
      return json(fora);
    } else if (acao === 'iniciar') {
      if (b.autorizado !== true) { log('400 sem autorizacao'); return json({ error: 'Marque que o titular autorizou a consulta.' }, 400); }
      const cpf = so(b.cpf);
      if (!cpfValido(cpf)) { log('400 cpf invalido'); return json({ error: 'CPF inválido (confira os dígitos).' }, 400); }
      const corpo: Record<string, unknown> = { cpf, origem: `niogen:${perfil}` };
      // 26/11 (Ricardo, "dados fictícios" da tela Consulta): só o CPF é do cliente — endereço, celular e e-mail saem do rodízio
      // guardado no .env do operador (CREDITO_FIC_*). Só pessoa logada (admin/backoffice); a Mari nunca usa.
      const fic = b.ficticio === true && servico !== true;
      if (fic) corpo.ficticio = true;
      const e = fic ? null : (b.endereco ?? null);
      if (e && so(e.cep)) {
        if (so(e.cep).length !== 8) return json({ error: 'CEP do cliente com 8 dígitos.' }, 400);
        corpo.endereco = {
          cep: so(e.cep), numero: String(e.numero ?? '').trim().slice(0, 20),
          complemento: String(e.complemento ?? '').trim().slice(0, 60), referencia: String(e.referencia ?? '').trim().slice(0, 80),
          opcao: String(e.opcao ?? '').trim().slice(0, 200),   // endereço escolhido na lista do portal (botão da tela)
          logradouro_esperado: await ruaEsperada(e),
        };
      }
      const c = fic ? null : (b.contato ?? null);
      if (c && (so(c.celular) || String(c.email ?? '').trim())) {
        corpo.contato = { celular: so(c.celular), email: String(c.email ?? '').trim().slice(0, 120) };
      }
      r = await fetch(`${opUrl}/credito`, { method: 'POST', headers: hdr, body: JSON.stringify(corpo), signal: AbortSignal.timeout(15000) });
    } else if (acao === 'viabilidade') {
      const e = b.endereco ?? {};
      if (so(e.cep).length !== 8) return json({ error: 'CEP com 8 dígitos.' }, 400);
      const corpo = {
        origem: `niogen:${perfil}`,
        // 19/11 (L-203): consulta pedida por pessoa logada abre o portal de novo (o cache de 6 h escondia a fachada recém-cadastrada); a Mari segue no cache.
        forcar: servico !== true,
        endereco: {
          cep: so(e.cep), numero: String(e.numero ?? '').trim().slice(0, 20),
          complemento: String(e.complemento ?? '').trim().slice(0, 60), referencia: String(e.referencia ?? '').trim().slice(0, 80),
          opcao: String(e.opcao ?? '').trim().slice(0, 200),
          logradouro_esperado: await ruaEsperada(e),
        },
      };
      r = await fetch(`${opUrl}/credito/viabilidade`, { method: 'POST', headers: hdr, body: JSON.stringify(corpo), signal: AbortSignal.timeout(15000) });
    } else if (acao === 'duplicidade') {
      // 12/11 (Ricardo): pedido Nio em aberto para o CPF — Etapas 0–3 com o endereço padrão, sem contato e sem crédito.
      const cpf = so(b.cpf);
      if (!cpfValido(cpf)) { log('400 cpf invalido'); return json({ error: 'CPF inválido (confira os dígitos).' }, 400); }
      r = await fetch(`${opUrl}/credito/duplicidade`, { method: 'POST', headers: hdr, body: JSON.stringify({ cpf, origem: `niogen:${perfil}` }), signal: AbortSignal.timeout(15000) });
    } else if (acao === 'status') {
      const id = String(b.job_id ?? '');
      if (!/^[0-9a-f]{32}$/.test(id)) return json({ error: 'job inválido.' }, 400);
      r = await fetch(`${opUrl}/credito/${id}`, { headers: hdr, signal: AbortSignal.timeout(10000) });
    } else if (acao === 'print') {
      const id = String(b.job_id ?? '');
      if (!/^[0-9a-f]{32}$/.test(id)) return json({ error: 'job inválido.' }, 400);
      // 25/11: parte 'viab' = print da viabilidade tirado no meio da consulta de crédito (Etapa 2, antes do CPF)
      const parte = b.parte === 'viab' ? '/viab' : '';
      r = await fetch(`${opUrl}/credito/print/${id}${parte}`, { headers: hdr, signal: AbortSignal.timeout(15000) });
      const d = await r.json().catch(() => null);
      if (!d || !r.ok || d.ok === false) { log(`print ${r.status}`); return json({ error: d?.erro ?? `Operador respondeu ${r.status}.` }, r.status === 404 ? 404 : 502); }
      log('print ok');
      return json({ tipo: d.tipo, base64: d.base64, em: d.em });
    } else {
      return json({ error: 'acao deve ser iniciar, viabilidade, duplicidade, status, print, os ou os_status.' }, 400);
    }
    const d = await r.json().catch(() => null);
    if (!d) { log(`502 operador ${r.status} sem json`); return json({ error: `Operador respondeu ${r.status} sem JSON (rota do proxy?).` }, 502); }
    if (!r.ok || d.ok === false) {
      log(`${r.status} ${d.erro ?? ''}`);
      return json({ error: d.erro ?? `Operador respondeu ${r.status}.` }, r.status === 429 ? 429 : r.status === 400 ? 400 : 502);
    }
    delete d.ok;
    log(`${d.estado}${d.resultado ? ` ${d.resultado}` : ''}${d.cache ? ' cache' : ''}`);
    return json(d);
  } catch (e) {
    const m = (e as Error)?.name === 'TimeoutError' ? 'Operador de crédito sem resposta.' : 'Operador de crédito fora do ar.';
    log(`502 ${(e as Error)?.name}`);
    return json({ error: m }, 502);
  }
});

// 14/11/2026 (Helton — docs/Prompt_dfv_api_e_rua_do_portal_141126_1935.md, parte B): a rua que o operador confere antes de aceitar o
// endereço que o portal resolveu. Vem do pedido (a rua que o cliente confirmou, mandada pela Mari/tela) ou, sem ela, do ViaCEP
// pelo CEP (só o CEP sai daqui; 4 s no máximo). Sem nenhuma das duas: '' e o operador segue como antes. Opção tocada na tela
// (e.opcao) é escolha do humano — o operador não confere.
// deno-lint-ignore no-explicit-any
async function ruaEsperada(e: any): Promise<string> {
  const dada = String(e?.logradouro_esperado ?? '').trim().slice(0, 120);
  if (dada || String(e?.opcao ?? '').trim()) return dada;
  const cep = so(e?.cep);
  if (cep.length !== 8) return '';
  try {
    const r = await fetch(`https://viacep.com.br/ws/${cep}/json/`, { signal: AbortSignal.timeout(4000) });
    const d = await r.json().catch(() => null);
    return d && !d.erro ? String(d.logradouro ?? '').trim().slice(0, 120) : '';
  } catch {
    return '';
  }
}
