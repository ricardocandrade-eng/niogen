-- NIOGEN | supabase/migrations/0297_sugerir_resposta_ia.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Prompt: docs/Prompt_sugerir_resposta_ia_181126_1825.md (Drive). Ricardo, 18/11 ~18h20: "é possível um botão de IA que, ao
-- clicar, lê a conversa e sugere a resposta?"
-- O que nasce (o banco do botão ✨ Sugerir resposta — a chamada ao Claude é da edge function sugerir-resposta):
--   · config_regras.sugestao_ia — liga/desliga, modelo, fallback, tetos, max_tokens (nada fixo no código — regra 15).
--   · sugestoes_ia — uma linha por clique: quem pediu, modelo, tokens, custo, latência, as 2 opções, qual foi escolhida, o texto
--     que saiu e quanto foi editado. É a medição dos 7 dias (minutos até a 1ª resposta humana, % que saiu de sugestão, edição, US$).
--   · _sug_mascarar(texto) — tira e-mail, CPF/CNPJ, telefone e número longo (cartão/conta) do que vai ao modelo.
--   · sugestao_contexto(conversa) — SÓ service_role (a edge function): o mínimo para escrever a próxima frase. Últimos 20 turnos
--     mascarados, situação/vez/prazo, etapa e o que fazer (v_jornada), a venda (plano, valor, forma, crédito, biometria, OS),
--     a tabela vigente do cluster, a janela de 24 h, não contatar e o uso do dia (tetos). Nunca CPF, e-mail, telefone, cartão, conta.
--   · sugestao_registrar(...) — SÓ service_role: grava a chamada e o custo.
--   · sugestao_resultado(id, escolhida, texto, acao_id) — admin/backoffice, o dono do clique: escolhida (1/2/0 = dispensou),
--     o texto enviado, a distância de edição (% de palavras alteradas) e, quando enviada, a nota privada
--     "✨ sugerida pelo NIOGEN, enviada por <nome>" pela porta de sempre (backoffice_responder com p_nota).
-- Desvio do prompt (item 5): backoffice_responder NÃO ganha p_sugestao_id — é casca da porta em sombra (0263; mudar a assinatura
-- = reescrever a casca, que o portão barra pela R11). O envio é amarrado à sugestão depois, por sugestao_resultado(..., p_acao_id).
-- Regra 20 (as cinco):
--   (1) nenhum estado de lead nasce ou muda: sem etapa, situação, destino, dono, etiqueta, cadência, pendência;
--   (2) o envio continua em backoffice_responder (porta); a edge function grava só sugestoes_ia;
--   (3) o botão some/explica com não contatar, Saída definitiva, janela fechada e teto batido (sugestao_contexto devolve o motivo);
--   (4) fonte única: a conversa vem de mari_turnos, o estado de v_lead_situacao/v_jornada, a tabela de config_planos;
--   (5) conferência: sem número de operação novo — sugestoes_ia é medição, não conta que precise fechar (não entra em conferencia_itens).
-- Regra de ouro 10 (função nova declara): sugestao_registrar e sugestao_resultado NÃO criam evento de lead; são registro, não estado.
--   sugestao_resultado chama backoffice_responder(p_nota := true) — evento time_nota, que já existe e não muda situação.
-- Desempenho: nada na abertura da conversa; só no clique (1 RPC de contexto + 1 de registro, ambas pela edge function).

begin;

-- ---------- config ----------
insert into public.config_regras (chave, valor)
values ('sugestao_ia', jsonb_build_object(
  'ligado', true,
  'modelo', 'claude-sonnet-5-5',
  'modelo_fallback', 'claude-haiku-5-5',
  'teto_dia', 120,
  'teto_conversa_dia', 10,
  'max_tokens', 500,
  'turnos', 20,
  'preco', jsonb_build_object(   -- US$ por milhão de tokens (entrada, saída, leitura de cache, escrita de cache 5 min)
    'claude-sonnet-5-5', jsonb_build_object('in', 2, 'out', 10, 'cache_read', 0.10, 'cache_write', 2.5),
    'claude-haiku-5-5',  jsonb_build_object('in', 0.10, 'out', 0.50, 'cache_read', 0.01, 'cache_write', 0.125))))
on conflict (chave) do nothing;

-- ---------- tabela ----------
create table if not exists public.sugestoes_ia (
  id               uuid primary key default gen_random_uuid(),
  parceiro_id      text not null default 'dharma',
  conversa_id      uuid not null references public.mari_conversas(id) on delete cascade,
  venda_id         uuid,
  usuario_id       uuid,
  pedida_em        timestamptz not null default now(),
  modelo           text,
  tokens_entrada   int,
  tokens_saida     int,
  tokens_cache     int,            -- lidos do cache
  tokens_cache_esc int,            -- escritos no cache
  custo_usd        numeric(10,6),
  latencia_ms      int,
  opcoes           jsonb,          -- [{rotulo, texto}, {rotulo, texto}]
  aviso            text,           -- o que a tela mostra junto (ex.: rascunho do modelo reserva)
  escolhida        smallint check (escolhida in (0, 1, 2)),   -- 0 = dispensou as duas
  escolhida_em     timestamptz,
  texto_enviado    text,
  enviada          boolean not null default false,
  acao_id          bigint,         -- a mensagem na chatwoot_acoes (backoffice_responder)
  distancia_edicao numeric(5,1),   -- % de palavras alteradas entre a opção escolhida e o que saiu
  erro             text
);
comment on table public.sugestoes_ia is '0297: cada clique em ✨ Sugerir resposta (Conversas e ficha). Medição, não estado de lead. Escrita só por sugestao_registrar (edge sugerir-resposta) e sugestao_resultado.';
create index if not exists sugestoes_ia_pedida on public.sugestoes_ia (pedida_em desc);
create index if not exists sugestoes_ia_conversa on public.sugestoes_ia (conversa_id, pedida_em desc);

alter table public.sugestoes_ia enable row level security;
drop policy if exists sugestoes_ia_ler on public.sugestoes_ia;
create policy sugestoes_ia_ler on public.sugestoes_ia for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke insert, update, delete on public.sugestoes_ia from anon, authenticated;

-- ---------- máscara ----------
create or replace function public._sug_mascarar(p text)
returns text language sql immutable set search_path = public as $$
  select regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(coalesce(p, ''),
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[e-mail]', 'g'),
    '\d{2}\.?\d{3}\.?\d{3}/?\d{4}-?\d{2}', '[CNPJ]', 'g'),
    '(\d[ .-]?){12,18}\d', '[número]', 'g'),                                   -- cartão, conta, telefone com 55
    '\d{3}\.?\d{3}\.?\d{3}-?(\d{2})', '***.***.***-\1', 'g'),                  -- CPF: só os 2 últimos, como a ficha
    '\(?\d{2}\)?[ .-]?9?\d{4}[ .-]?\d{4}', '[telefone]', 'g')
$$;

-- ---------- contexto (só a edge function) ----------
create or replace function public.sugestao_contexto(p_conversa uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c        public.mari_conversas;
  v        public.vendas;
  cfg      jsonb := coalesce((select valor from public.config_regras where chave = 'sugestao_ia'), '{}'::jsonb);
  n_turnos int := coalesce((cfg ->> 'turnos')::int, 20);
  ult_lead timestamptz;
  sit      record;
  jor      record;
  planos   jsonb;
  turnos   jsonb;
  plano    jsonb;
  hoje     timestamptz := date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
begin
  select * into c from public.mari_conversas where id = p_conversa;
  if not found then return jsonb_build_object('erro', 'Conversa não encontrada.'); end if;
  if c.venda_id is not null then select * into v from public.vendas where id = c.venda_id; end if;

  select max(t.created_at) into ult_lead from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead';
  ult_lead := coalesce(ult_lead, c.ultima_msg_lead_at);

  select s.situacao, s.situacao_nome, s.destino, s.vez, s.prazo_em, s.em_espera into sit
    from public.v_lead_situacao s where s.conversa_id = c.id limit 1;
  select j.etapa_nome, j.o_que_fazer, j.dono_tipo, j.pendencia, j.portal_status, j.biometria_ged into jor
    from public.v_jornada j where j.conversa_id = c.id limit 1;

  select coalesce(jsonb_agg(x order by x ->> 'em'), '[]'::jsonb) into turnos from (
    select jsonb_build_object(
             'quem', case t.papel when 'lead' then 'cliente' when 'mari' then 'Mari' else 'time' end,
             'em', to_char(t.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
             'texto', left(public._sug_mascarar(
                        regexp_replace(regexp_replace(t.texto, '\[HANDOFF\][\s\S]*?(\[/HANDOFF\]|$)', '', 'gi'),
                                       '\[[A-Z_]{3,}(:[^\]]*)?\]', '', 'g')), 700)) x
      from public.mari_turnos t
     where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano') and btrim(coalesce(t.texto, '')) <> ''   -- sistema: o estado vem da situação/jornada
     order by t.created_at desc, t.id desc limit n_turnos) z;

  if c.cluster is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'nome', nome, 'portfolio', portfolio, 'variante', variante, 'velocidade_mb', velocidade_mb, 'wifi', wifi,
             'internet_5g', internet_5g, 'inclusos', to_jsonb(inclusos), 'preco', preco, 'preco_cartao', preco_cartao,
             'taxa_habilitacao', taxa_habilitacao, 'isencao_meses', isencao_meses) order by portfolio desc, variante, preco), '[]'::jsonb)
      into planos
      from public.config_planos
     where ativo and cluster = c.cluster and (vigencia_fim is null or vigencia_fim >= current_date);
  end if;
  if v.plano_id is not null then
    select jsonb_build_object('nome', p.nome, 'preco', p.preco, 'preco_cartao', p.preco_cartao) into plano from public.config_planos p where p.id = v.plano_id;
  end if;

  return jsonb_build_object(
    'config', cfg,
    'conversa_id', c.id,
    'venda_id', c.venda_id,
    'primeiro_nome', nullif(split_part(btrim(coalesce(c.dados ->> 'nome', c.nome_contato, '')), ' ', 1), ''),
    'nao_contatar', coalesce(c.nao_contatar, false),
    'janela', jsonb_build_object(
      'aberta', ult_lead is not null and now() < ult_lead + interval '23 hours',
      'ultima_msg_cliente', to_char(ult_lead at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')),
    'situacao', case when sit.situacao is null then null else jsonb_build_object(
      'codigo', sit.situacao, 'nome', sit.situacao_nome, 'destino', sit.destino, 'vez', sit.vez,
      'prazo', to_char(sit.prazo_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), 'em_espera', sit.em_espera) end,
    'jornada', case when jor.etapa_nome is null and jor.o_que_fazer is null then null else jsonb_build_object(
      'etapa', jor.etapa_nome, 'o_que_fazer', jor.o_que_fazer, 'dono', jor.dono_tipo, 'pendencia', jor.pendencia,
      'portal', jor.portal_status, 'biometria', jor.biometria_ged) end,
    'endereco', jsonb_strip_nulls(jsonb_build_object('tem_cep', c.cep is not null, 'tem_numero', c.numero is not null,
      'cidade', c.cidade, 'uf', c.uf, 'bairro', c.endereco_cep ->> 'bairro',
      'dentro_area', c.dentro_area, 'cobertura', c.cobertura_decisao, 'viabilidade_nio', c.nio_viab_resultado)),
    'lead', jsonb_strip_nulls(jsonb_build_object('origem', c.origem, 'plano_escolhido', c.plano_escolhido,
      'forma_pagamento', c.forma_pagamento, 'credito', c.credito_resultado, 'preferencia_instalacao', c.instalacao_preferencia,
      'tem_cpf', case when length(regexp_replace(coalesce(c.dados ->> 'cpf', ''), '\D', '', 'g')) = 11
                      then '***.***.***-' || right(regexp_replace(c.dados ->> 'cpf', '\D', '', 'g'), 2) end)),
    'venda', case when v.id is null then null else jsonb_strip_nulls(jsonb_build_object(
      'etapa', v.status, 'plano', plano, 'valor_mensal', v.valor_mensal, 'forma_pagamento', v.forma_pagamento,
      'credito', v.credito_resultado, 'biometria', v.biometria_status, 'tem_pedido', v.nio_pedido is not null,
      'tem_os', v.nio_os is not null, 'instalacao_agendada', to_char(v.instalacao_agendada_para at time zone 'America/Sao_Paulo', 'DD/MM'),
      'turno', v.instalacao_turno, 'pendencia_nio', v.nio_pendencia_desc, 'saida', v.saida_motivo)) end,
    'planos', coalesce(planos, '[]'::jsonb),
    'turnos', turnos,
    'uso', jsonb_build_object(
      'hoje', (select count(*) from public.sugestoes_ia where pedida_em >= hoje and erro is null),
      'hoje_conversa', (select count(*) from public.sugestoes_ia where pedida_em >= hoje and conversa_id = c.id and erro is null)));
end $$;
revoke all on function public.sugestao_contexto(uuid) from public, anon, authenticated;
grant execute on function public.sugestao_contexto(uuid) to service_role;

-- ---------- registro (só a edge function) ----------
create or replace function public.sugestao_registrar(
  p_conversa uuid, p_usuario uuid, p_modelo text, p_tokens_entrada int, p_tokens_saida int, p_tokens_cache int,
  p_tokens_cache_esc int, p_custo_usd numeric, p_latencia_ms int, p_opcoes jsonb, p_aviso text default null, p_erro text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.sugestoes_ia (conversa_id, venda_id, usuario_id, modelo, tokens_entrada, tokens_saida, tokens_cache, tokens_cache_esc,
                                   custo_usd, latencia_ms, opcoes, aviso, erro)
  select p_conversa, c.venda_id, p_usuario, p_modelo, p_tokens_entrada, p_tokens_saida, p_tokens_cache, p_tokens_cache_esc,
         p_custo_usd, p_latencia_ms, p_opcoes, p_aviso, left(p_erro, 500)
    from public.mari_conversas c where c.id = p_conversa
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.sugestao_registrar(uuid, uuid, text, int, int, int, int, numeric, int, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.sugestao_registrar(uuid, uuid, text, int, int, int, int, numeric, int, jsonb, text, text) to service_role;

-- ---------- distância de edição (palavras) ----------
create or replace function public._sug_distancia(a text, b text)
returns numeric language plpgsql immutable set search_path = public as $$
declare
  x text[] := coalesce(regexp_split_to_array(lower(btrim(coalesce(a, ''))), '\s+'), '{}');
  y text[] := coalesce(regexp_split_to_array(lower(btrim(coalesce(b, ''))), '\s+'), '{}');
  n int; m int; i int; j int; ant int[]; cur int[];
begin
  if btrim(coalesce(a, '')) = '' then x := '{}'; end if;
  if btrim(coalesce(b, '')) = '' then y := '{}'; end if;
  n := coalesce(array_length(x, 1), 0); m := coalesce(array_length(y, 1), 0);
  if greatest(n, m) = 0 then return 0; end if;
  if n = 0 or m = 0 then return 100; end if;
  ant := array(select generate_series(0, m));
  for i in 1..n loop
    cur := array[i];
    for j in 1..m loop
      cur := cur || least(ant[j + 1] + 1, cur[j] + 1, ant[j] + case when x[i] = y[j] then 0 else 1 end);
    end loop;
    ant := cur;
  end loop;
  return round(100.0 * ant[m + 1] / greatest(n, m), 1);
end $$;

-- ---------- resultado (a tela) ----------
create or replace function public.sugestao_resultado(p_id uuid, p_escolhida int, p_texto text default null, p_acao_id bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s     public.sugestoes_ia;
  quem  text;
  base  text;
  d     numeric;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  if p_escolhida not in (0, 1, 2) then raise exception 'Escolha inválida.'; end if;
  select * into s from public.sugestoes_ia where id = p_id for update;
  if not found then raise exception 'Sugestão não encontrada.'; end if;
  if s.usuario_id is distinct from auth.uid() then raise exception 'Esta sugestão é de outra pessoa.' using errcode = '42501'; end if;
  if s.enviada then return jsonb_build_object('ok', true, 'ja', true); end if;

  if p_escolhida = 0 or p_acao_id is null then
    -- dispensou, ou escolheu e ainda não mandou: grava a escolha (a última vale)
    update public.sugestoes_ia set escolhida = p_escolhida, escolhida_em = now() where id = p_id;
    return jsonb_build_object('ok', true);
  end if;

  base := s.opcoes -> (p_escolhida - 1) ->> 'texto';
  d := public._sug_distancia(base, p_texto);
  update public.sugestoes_ia
     set escolhida = p_escolhida, escolhida_em = coalesce(escolhida_em, now()), texto_enviado = left(p_texto, 4000),
         enviada = true, acao_id = p_acao_id, distancia_edicao = d
   where id = p_id;

  select nome into quem from public.usuarios where id = auth.uid();
  begin
    perform public.backoffice_responder(s.conversa_id, '✨ sugerida pelo NIOGEN, enviada por ' || coalesce(quem, 'alguém do time')
      || case when d = 0 then ' (sem edição)' else ' (' || d || '% editada)' end, true, null);
  exception when others then
    null;   -- a nota é registro: falhar nela não desfaz a medição nem a mensagem (que já saiu)
  end;
  return jsonb_build_object('ok', true, 'distancia_edicao', d);
end $$;
revoke all on function public.sugestao_resultado(uuid, int, text, bigint) from public, anon;
grant execute on function public.sugestao_resultado(uuid, int, text, bigint) to authenticated;

commit;
