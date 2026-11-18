// NIOGEN | supabase/functions/sugerir-resposta/index.ts | 18/11/2026 — Claude Code (Opus 5.5)
// Botão ✨ Sugerir resposta (Conversas e ficha) — docs/Prompt_sugerir_resposta_ia_181126_1825.md (Drive).
// SÍNCRONA, chamada pelo front do usuário logado (padrão da credito-consulta). Só admin e backoffice.
//   POST {conversa_id} → {sugestao_id, opcoes: [{rotulo, texto}, {rotulo, texto}], modelo, aviso?}
//                      | {bloqueio: 'janela_fechada' | 'nao_contatar' | 'saida' | 'teto' | 'desligado', mensagem}
// A IA NUNCA envia: devolve texto para a caixa; quem envia é a pessoa, pela backoffice_responder de sempre.
// Contexto: sugestao_contexto(conversa) — mascarado no banco (sem CPF completo, e-mail, telefone, cartão, conta).
// Motor (config_regras.sugestao_ia): claude-sonnet-5-5 · cache no bloco fixo (voz + regras da Mari, gerado por
//   scripts/sugestao_regras.py) · esforço baixo, thinking só entre ferramentas (= sem raciocínio: aqui não há ferramenta) ·
//   saída em JSON schema · sem temperatura (o Sonnet 5.5 recusa valor fora do padrão) · sem streaming (resposta curta).
//   Recusa por política → fallback do próprio servidor ("default"). Erro da API 2 vezes → claude-haiku-5-5, marcado rascunho.
// Filtro de saída: 2 opções, tamanho, preço que não está na tabela vigente, palavra proibida, "Mari" → 1 reescrita; o que
//   ainda falhar é descartado (nunca sugestão inventada).
// Segredo: CLAUDE_API_KEY_NIO (Supabase › Edge Functions › Secrets) — gravado pelo Ricardo. Nada no front nem no repo.
// Log: usuário (8 primeiros), resultado, ms — nunca o texto da conversa nem o prompt.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import Anthropic from 'npm:@anthropic-ai/sdk@1.5.0';
import { REGRAS_MARI } from './regras.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

type Opcao = { rotulo: string; texto: string };
type Ctx = Record<string, any>;

// ---------- o bloco fixo (cacheado): voz + regras de conteúdo da Mari ----------
const VOZ = `Você ajuda o time de vendas de uma revenda credenciada da Nio Internet (internet fibra) a responder clientes no WhatsApp.
Uma PESSOA do time assumiu esta conversa e vai enviar a próxima mensagem. Você propõe 2 opções de texto; ela confere, edita e envia.

COMO ESCREVER (voz de pessoa, não da Mari):
- Escreva como o atendente humano, em primeira pessoa, português do Brasil, simples e educado. Frases curtas, como no WhatsApp.
- NÃO se apresente como a Mari, não diga "Aqui é a Mari", não repita apresentação se a conversa já está em andamento.
  O cliente acabou de passar para uma pessoa: se o texto sair com o jeito da Mari (emojis, entusiasmo, frases prontas), ele percebe a troca.
- Sem emoji por padrão. Um 😊 no máximo, e só se o cliente estiver usando emoji. As frases prontas das regras da Mari que terminam
  em 😊 ("o único desconto é o do cartão 😊") são usadas SEM o emoji quando o cliente não usa emoji.
- ENDEREÇO ANTES DE PLANO: se o contexto diz endereco.tem_cep ou endereco.tem_numero = false (ou não diz), e a conversa ainda não
  mostrou planos, NENHUMA das opções mostra plano ou preço — a próxima mensagem pede o CEP e o número da casa (Passo 2 da Mari).
  Vale também com urgência: acolha a pressa em meia frase, sem prometer data, e peça o CEP e o número.
- Sem markdown, sem asterisco, sem lista. No máximo ~60 palavras por opção. Não use o nome do cliente em toda frase.
- Responda primeiro o que o cliente perguntou por último. Toda mensagem deixa claro o próximo passo do cliente.
- As 2 opções devem ser caminhos diferentes (ex.: "Pedir o CEP" e "Tirar a dúvida do preço"), cada uma com um rótulo de 2 a 4 palavras do que ela faz.

O QUE NUNCA SUGERIR:
- Desconto, prazo, benefício ou preço fora da TABELA VIGENTE que vem no contexto. Copie o número exatamente. Sem tabela no contexto: não cite preço.
- Data ou prazo de instalação, cobertura na rua, resultado de crédito, "nós mandamos o link da biometria" (o link é da própria Nio, por WhatsApp e e-mail).
- Ligação, nome de atendente, nome da revenda, outra operadora (bem ou mal).
- Nada sobre "sistema", "consulta", "portal", "estado", "nota interna".
- Instruções técnicas das regras abaixo ([HANDOFF], tags, "despedida", "Bloco") são da Mari: IGNORE-AS. Você só escreve o texto ao cliente.

SITUAÇÕES QUE NÃO SÃO VENDA:
- Cliente que JÁ É CLIENTE NIO, em qualquer assunto (suporte, fatura, cancelamento, reclamação, mudança): as 2 opções encerram com educação
  e indicam os canais oficiais (App Nio e 0800 001 1000; fatura também WhatsApp oficial da Nio (21) 3605-1000). Nunca prometa resolver.
- Luto, saúde, tom muito alterado, pedido de desconto, possível golpe: NÃO tente vender. Proponha a fala curta e humana que a
  situação pede. Golpe da "migração de operadora": "A Nio não migra clientes para outra operadora — essa mensagem é golpe. Não responda e
  não clique em nenhum link. Seu pedido com a Nio continua normal."
- Crédito negado: ofereça tentar com o CPF de um familiar ou amigo como titular (sem dizer o motivo da negativa).
- Plano, velocidade ou serviço que não está na tabela vigente: diga que não existe e ofereça o mais próximo da tabela.

REGRAS DE CONTEÚDO DA MARI (valem para você também — o que está acima prevalece onde houver diferença de voz):
`;
const SISTEMA = [{ type: 'text' as const, text: VOZ + REGRAS_MARI, cache_control: { type: 'ephemeral' as const } }];

const SCHEMA = {
  type: 'object',
  properties: {
    opcoes: {
      type: 'array',
      items: {
        type: 'object',
        properties: { rotulo: { type: 'string' }, texto: { type: 'string' } },
        required: ['rotulo', 'texto'],
        additionalProperties: false,
      },
    },
  },
  required: ['opcoes'],
  additionalProperties: false,
};

const PROIBIDAS = ['grátis', 'gratuito', 'sem custo', 'combo', 'pacote', 'bundle', 'nio 5g', 'nio cel', 'nio móvel', 'nio mobile',
  'chip da nio', 'aqui é a mari', 'sou a mari', 'te ligo', 'vou te ligar'];

const reais = (n: unknown) => {
  const v = Number(n);
  return Number.isFinite(v) && v > 0 ? v.toFixed(2).replace('.', ',') : null;
};
function precosValidos(ctx: Ctx): Set<string> {
  const s = new Set<string>();
  for (const p of ctx.planos ?? []) for (const k of ['preco', 'preco_cartao', 'taxa_habilitacao']) { const r = reais(p[k]); if (r) s.add(r); }
  const pv = ctx.venda?.plano;
  if (pv) for (const k of ['preco', 'preco_cartao']) { const r = reais(pv[k]); if (r) s.add(r); }
  const vm = reais(ctx.venda?.valor_mensal); if (vm) s.add(vm);
  return s;
}
// Devolve o problema da opção (ou null se está boa).
function problema(o: Opcao, precos: Set<string>): string | null {
  const t = String(o.texto ?? '').trim();
  if (!t) return 'texto vazio';
  if (t.split(/\s+/).length > 75 || t.length > 500) return 'texto longo demais (máximo ~60 palavras)';
  if (/[*_#`]{2,}|^\s*[-•]\s/m.test(t)) return 'tem markdown ou lista';
  const baixo = t.toLowerCase();
  const p = PROIBIDAS.find((w) => baixo.includes(w));
  if (p) return `usa "${p}"`;
  for (const m of t.matchAll(/R\$\s?(\d{1,4}(?:[.,]\d{2})?)/g)) {
    const n = m[1].includes(',') ? m[1] : m[1].includes('.') ? m[1].replace('.', ',') : `${m[1]},00`;
    if (!precos.has(n)) return `cita R$ ${m[1]}, que não está na tabela vigente`;
  }
  return null;
}
const limpa = (o: Opcao): Opcao => ({
  rotulo: String(o.rotulo ?? '').replace(/[*_#`"]/g, '').trim().split(/\s+/).slice(0, 5).join(' ') || 'Sugestão',
  texto: String(o.texto ?? '').replace(/\*\*/g, '').trim(),
});

function montarPedido(ctx: Ctx, nomeUsuario: string): string {
  const { turnos, config: _c, uso: _u, ...estado } = ctx;
  const conversa = (turnos ?? []).map((t: any) => `[${t.em}] ${t.quem}: ${t.texto}`).join('\n');
  return `ESTADO DO CLIENTE (do banco; vale mais que o que você deduzir da conversa):
${JSON.stringify({ ...estado, quem_vai_enviar: nomeUsuario ? nomeUsuario.split(' ')[0] : 'atendente' }, null, 1)}

TABELA VIGENTE = o campo "planos" acima (vazio = cidade ainda sem tabela: não cite preço).

CONVERSA (mais antiga → mais recente; dados pessoais mascarados):
${conversa || '(sem mensagens)'}

Escreva 2 opções para a PRÓXIMA mensagem da pessoa do time ao cliente.`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405);
  const t0 = Date.now();
  let usuario = '?';
  const log = (r: string) => console.log(`sugerir-resposta · ${usuario} · ${r} · ${Date.now() - t0} ms`);
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const servico = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const adm = createClient(url, servico, { auth: { persistSession: false } });
    const b = await req.json().catch(() => ({}));
    // Modo teste (tests/sugestao_portao.py): só com a chave de serviço; contexto sintético no corpo; não lê nem grava o banco
    // (a config vem de config_regras, a mesma do clique). Mesmo prompt, mesmo filtro, mesmos freios.
    // (como a credito-consulta: a chave do pedido segue adiante e o banco responde sou_service_role())
    let teste = false;
    if (b.teste && typeof b.teste === 'object') {
      const q = createClient(url, req.headers.get('apikey') || Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
      const { data: sr } = await q.rpc('sou_service_role');
      teste = sr === true;
      if (!teste) return json({ error: 'Modo teste só com a chave de serviço.' }, 403);
    }
    let uid: string | null = null;
    let conversaId = '';
    let ctx: Ctx;
    let nomeUsuario = '';
    if (teste) {
      usuario = 'portao';
      const { data: rc } = await adm.from('config_regras').select('valor').eq('chave', 'sugestao_ia').maybeSingle();
      ctx = { ...b.teste, config: rc?.valor ?? {}, uso: { hoje: 0, hoje_conversa: 0 } };
      nomeUsuario = 'Teste';
    } else {
      const quem = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
      const [{ data: perfil }, { data: u }] = await Promise.all([quem.rpc('meu_perfil'), quem.auth.getUser()]);
      uid = u?.user?.id ?? null;
      usuario = uid?.slice(0, 8) ?? '?';
      if (!uid || !['admin', 'backoffice'].includes(String(perfil))) { log(`403 ${perfil}`); return json({ error: 'A sugestão é só do backoffice.' }, 403); }
      conversaId = String(b.conversa_id ?? '');
      if (!/^[0-9a-f-]{36}$/.test(conversaId)) return json({ error: 'conversa inválida.' }, 400);
      const [{ data: c, error: eCtx }, { data: eu }] = await Promise.all([
        adm.rpc('sugestao_contexto', { p_conversa: conversaId }),
        adm.from('usuarios').select('nome').eq('id', uid).maybeSingle(),
      ]);
      if (eCtx || !c || c.erro) { log('erro contexto'); return json({ error: c?.erro ?? 'Não consegui ler a conversa.' }, 500); }
      ctx = c;
      nomeUsuario = eu?.nome ?? '';
    }
    const cfg = ctx.config ?? {};
    const registrar = (p: Record<string, unknown>) => (teste ? Promise.resolve({ data: null })
      : adm.rpc('sugestao_registrar', { p_conversa: conversaId, p_usuario: uid, ...p }));

    // ---------- freios (o botão some na tela; aqui é a garantia) ----------
    if (cfg.ligado === false) return json({ bloqueio: 'desligado', mensagem: 'A sugestão por IA está desligada nas configurações.' });
    if (ctx.nao_contatar || ctx.situacao?.codigo === 'nao_contatar') return json({ bloqueio: 'nao_contatar', mensagem: 'O cliente pediu para não ser contatado.' });
    if (ctx.situacao?.codigo === 'saida_definitiva') return json({ bloqueio: 'saida', mensagem: 'Conversa em Saída definitiva: sem sugestão.' });
    if (!ctx.janela?.aberta) return json({ bloqueio: 'janela_fechada', mensagem: 'Janela de 24 h fechada: só template aprovado. Escolha um em "Respostas rápidas › Templates aprovados".' });
    if (ctx.uso?.hoje >= (cfg.teto_dia ?? 120)) return json({ bloqueio: 'teto', mensagem: `O limite de ${cfg.teto_dia ?? 120} sugestões por dia foi atingido. As Respostas rápidas continuam disponíveis.` });
    if (ctx.uso?.hoje_conversa >= (cfg.teto_conversa_dia ?? 10)) return json({ bloqueio: 'teto', mensagem: 'Muitas sugestões nesta conversa hoje. Use as Respostas rápidas.' });

    // 18/11: o Ricardo gravou o segredo com o nome da credencial do n8n ("Claude API Nio") — valem os dois nomes
    const chave = (Deno.env.get('CLAUDE_API_KEY_NIO') || Deno.env.get('Claude API Nio') || '').trim().replace(/^Bearer\s+/i, '').replace(/^["']|["']$/g, '');
    if (!chave) { log('503 sem chave'); return json({ error: 'Sugestão por IA ainda não instalada (falta a chave da API).', nao_instalado: true }, 503); }
    const cli = new Anthropic({ apiKey: chave, maxRetries: 0, timeout: 15000 });
    const modelo = String(cfg.modelo ?? 'claude-sonnet-5-5');
    const reserva = String(cfg.modelo_fallback ?? 'claude-haiku-5-5');
    const maxTokens = Number(cfg.max_tokens ?? 500);
    const precos = precosValidos(ctx);
    const uso = { in: 0, out: 0, cr: 0, cw: 0 };
    const custo = (m: string) => {
      const p = cfg.preco?.[m] ?? { in: 2, out: 10, cache_read: 0.1, cache_write: 2.5 };
      return (uso.in * p.in + uso.out * p.out + uso.cr * p.cache_read + uso.cw * p.cache_write) / 1e6;
    };

    async function chamar(m: string, mensagens: Anthropic.Beta.BetaMessageParam[]) {
      const ehSonnet = m.startsWith('claude-sonnet');
      const r = await cli.beta.messages.create({
        model: m,
        max_tokens: maxTokens,
        system: SISTEMA,
        messages: mensagens,
        output_config: { effort: 'low', format: { type: 'json_schema', schema: SCHEMA } },
        ...(ehSonnet ? { thinking: { type: 'between_tools' }, betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default' } : {}),
      } as any);
      uso.in += r.usage?.input_tokens ?? 0;
      uso.out += r.usage?.output_tokens ?? 0;
      uso.cr += r.usage?.cache_read_input_tokens ?? 0;
      uso.cw += r.usage?.cache_creation_input_tokens ?? 0;
      if (r.stop_reason === 'refusal') throw new Error('o modelo recusou');
      const txt = (r.content as any[]).filter((c) => c.type === 'text').map((c) => c.text).join('');
      const d = JSON.parse(txt);
      return { bruto: txt, opcoes: (Array.isArray(d?.opcoes) ? d.opcoes : []).map(limpa) as Opcao[] };
    }

    const pedido: Anthropic.Beta.BetaMessageParam[] = [{ role: 'user', content: montarPedido(ctx, nomeUsuario) }];
    let usado = modelo;
    let aviso: string | null = null;
    let res: { bruto: string; opcoes: Opcao[] } | null = null;
    let ultimoErro = '';
    for (let i = 0; i < 2 && !res; i++) {
      try { res = await chamar(modelo, pedido); } catch (e) { ultimoErro = String((e as Error)?.message ?? e).slice(0, 200); }
    }
    if (!res) {
      try {
        res = await chamar(reserva, pedido);
        usado = reserva;
        aviso = 'Rascunho do modelo reserva (o principal falhou) — confira com mais cuidado.';
      } catch (e) { ultimoErro = String((e as Error)?.message ?? e).slice(0, 200); }
    }
    if (!res) {
      await registrar({ p_modelo: usado, p_tokens_entrada: uso.in, p_tokens_saida: uso.out,
        p_tokens_cache: uso.cr, p_tokens_cache_esc: uso.cw, p_custo_usd: custo(usado), p_latencia_ms: Date.now() - t0, p_opcoes: null, p_erro: ultimoErro });
      log(`erro modelo: ${ultimoErro}`);
      return json({ error: 'A IA não respondeu agora. Tente de novo em instantes — ou use as Respostas rápidas.', ...(teste ? { detalhe: ultimoErro, chave_formato: { sk_ant: chave.startsWith('sk-ant-'), tamanho: chave.length } } : {}) }, 502);
    }

    // ---------- filtro de saída: 1 reescrita, depois descarta o que falhar ----------
    const falhas = res.opcoes.slice(0, 2).map((o, i) => [i, problema(o, precos)] as const).filter(([, p]) => p);
    if (res.opcoes.length < 2 || falhas.length) {
      const motivo = [res.opcoes.length < 2 ? 'faltou opção (são 2)' : '', ...falhas.map(([i, p]) => `opção ${i + 1}: ${p}`)].filter(Boolean).join('; ');
      try {
        const nova = await chamar(usado, [...pedido, { role: 'assistant', content: res.bruto },
          { role: 'user', content: `Reescreva as 2 opções corrigindo: ${motivo}. Preço só os da tabela vigente, exatamente.` }]);
        res = nova;
      } catch { /* fica a primeira; o que falhar é descartado abaixo */ }
    }
    // Emoji só se o cliente usa (18/11, Ricardo: "Ajusta o emoji"): sem emoji do cliente na conversa → tira os da sugestão
    const EMOJI = /[\p{Extended_Pictographic}\u{1F3FB}-\u{1F3FF}️‍]/gu;
    const clienteUsaEmoji = (ctx.turnos ?? []).some((t: any) => t.quem === 'cliente' && /\p{Extended_Pictographic}/u.test(String(t.texto ?? '')));
    if (!clienteUsaEmoji) res.opcoes = res.opcoes.map((o) => ({ ...o, texto: o.texto.replace(EMOJI, '').replace(/[ \t]{2,}/g, ' ').replace(/\s+([.,!?])/g, '$1').trim() }));
    const opcoes = res.opcoes.slice(0, 2).filter((o) => !problema(o, precos));
    if (!opcoes.length) aviso = null;
    const custoUsd = custo(usado);
    const { data: sid } = await registrar({ p_modelo: usado, p_tokens_entrada: uso.in,
      p_tokens_saida: uso.out, p_tokens_cache: uso.cr, p_tokens_cache_esc: uso.cw, p_custo_usd: custoUsd, p_latencia_ms: Date.now() - t0,
      p_opcoes: opcoes, p_aviso: aviso, p_erro: opcoes.length ? null : 'nenhuma opção passou no filtro' });
    log(`ok ${usado} ${opcoes.length} op · in ${uso.in} cache ${uso.cr}/${uso.cw} out ${uso.out} · US$ ${custoUsd.toFixed(4)}`);
    const extra = teste ? { uso, custo_usd: custoUsd } : {};
    if (!opcoes.length) return json({ error: 'A sugestão não passou na conferência (preço ou palavra fora da regra). Escreva à mão ou use as Respostas rápidas.', ...extra }, 422);
    return json({ sugestao_id: sid, opcoes, modelo: usado, aviso, latencia_ms: Date.now() - t0, ...extra });
  } catch (e) {
    log(`500 ${(e as Error)?.message ?? e}`);
    return json({ error: 'Falha ao sugerir. Tente de novo.' }, 500);
  }
});
