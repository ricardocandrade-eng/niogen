-- NIOGEN | supabase/migrations/0107_mari_ao_vivo_oportunidades.sql | 10/11/2026 — Claude Code
-- Prompt docs/Prompt_mari_ao_vivo_oportunidades_101126_1400.md (Ricardo, 10/11 13h55: "essa tela precisa mostrar que está viva",
-- "enviar para a Minha vez indicações de leads potenciais que cabe uma mensagem do humano", "tudo voltado em RESULTADO").
-- Só aditivo. Nada de prompt da Mari nem de cadência muda.
--   1. config_oportunidades (parceiro_id): linha 'geral' (ligado, max_dia 5, max_por_conversa_dia 1, max_parado_dias, janela_horas 23,
--      template de retomada, motivos do "Agora não") + uma linha por regra O1…O5 (ativo, pontos, parametros). Nenhum limiar no código.
--   2. oportunidades_log (parceiro_id): mostrada · enviada · dispensada · respondeu_24h · qualificou · pedido.
--   3. config_mari_textos op_O1…op_O5 — texto sugerido; {nome} {cidade} {plano} {valor} {agente}; trecho entre [ ] some se faltar a variável.
--   4. v_oportunidades (security_invoker): por conversa da Mari, as regras que bateram, pontos, motivo, valor_mes, janela, canal
--      (livre | template), texto_sugerido. Fora sempre: teste, venda, com humano/time, não contatar, em espera, já cliente Nio,
--      fora de área, endereço com Nio, encerrada (inclui silenciada suporte-nio), vez da Mari, humano falou por último.
--   5. oportunidade_enviar(conversa, texto, assumir, template): assumir=false → mensagem do time (balão de pessoa) SEM atribuir,
--      nota "🔥 Esquentada por … — a Mari segue" e um "desatribuir" DEPOIS da mensagem (se o eco do Chatwoot deixar dono, a conversa
--      volta para a Mari). assumir=true → backoffice_responder de sempre (assume, a Mari cala). oportunidade_dispensar(conversa, motivo).
--   6. oportunidades_atualizar(): grava "mostrada" e os resultados (respondeu_24h, qualificou, pedido) — chamada pelo Live/Painel/Mari.
--   7. mari_ao_vivo(): pulso (Ativa · Quieta · Parada?), funil de resultado do dia, R$ em negociação, nº de 🔥.
--   8. v_mari_feed (security_invoker): últimos 30 acontecimentos de hoje, frase curta + 1º nome. Sem CPF, telefone, endereço ou fala.
--   9. oportunidades_resumo(p_dias): mostradas · enviadas · responderam · qualificaram · pedidos (hoje e N dias) + controle (não enviadas).

-- ─────────────────────────────────────────────────────────────── 1. config
create table if not exists public.config_oportunidades (
  codigo        text primary key,
  parceiro_id   text not null default 'dharma',
  nome          text not null,
  ativo         boolean not null default true,
  pontos        integer not null default 0,
  ordem         integer not null default 0,
  parametros    jsonb not null default '{}'::jsonb,
  descricao     text,
  atualizado_em timestamptz not null default now()
);
alter table public.config_oportunidades enable row level security;
drop policy if exists config_oportunidades_ler on public.config_oportunidades;
create policy config_oportunidades_ler on public.config_oportunidades for select to authenticated using (public.meu_perfil() is not null);
drop policy if exists config_oportunidades_admin on public.config_oportunidades;
create policy config_oportunidades_admin on public.config_oportunidades for all to authenticated
  using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
revoke all on public.config_oportunidades from anon;
grant select, insert, update, delete on public.config_oportunidades to authenticated;

insert into public.config_oportunidades (codigo, nome, ativo, pontos, ordem, parametros, descricao) values
  ('geral', 'Geral', true, 0, 0,
   '{"ligado": true, "max_dia": 5, "max_por_conversa_dia": 1, "max_parado_dias": 7, "janela_horas": 23,
     "template": "nio_retomada_lead_d7",
     "dispensa_motivos": [{"codigo": "ja_falei", "nome": "Já falei"}, {"codigo": "nao_vale", "nome": "Não vale"}, {"codigo": "depois", "nome": "Depois"}]}',
   'ligado (desliga tudo) · max_dia (quantas por dia, contando as já enviadas/dispensadas hoje) · max_por_conversa_dia · max_parado_dias (conversa parada há mais que isso não entra) · janela_horas (texto livre só até N h depois da última mensagem do cliente; 23 = folga da Meta) · template (aprovado, 1 variável, usado com a janela fechada) · dispensa_motivos (botões do "Agora não")'),
  ('O1', 'Janela fechando', true, 50, 10, '{"fecha_em_horas": 4, "termometro_min": 2}',
   'Vez do cliente, janela de 24 h aberta e fecha em ≤ fecha_em_horas, e termômetro ≥ termometro_min OU já viu os planos. Pesa mais.'),
  ('O2', 'Viu os planos e sumiu', true, 40, 20, '{"min_horas_uteis": 2, "max_horas": 48}',
   'Coluna Planos apresentados, vez do cliente há ≥ min_horas_uteis (horário de atendimento) e ≤ max_horas.'),
  ('O3', 'Objeção parada', true, 35, 30, '{"min_horas_uteis": 1, "objecoes": ["preco", "pensar", "consultar_alguem"], "alertas": ["desconto"]}',
   'Objeção registrada pela Mari (dados.objecao) ou alerta do quadro (pediu desconto) e sem resposta há ≥ min_horas_uteis. Desconto: reforçar o valor da tabela — nunca desconto.'),
  ('O4', 'Quase pronto', true, 45, 40, '{"termometro_min": 6, "min_horas_uteis": 1}',
   'Termômetro ≥ termometro_min itens validados e parado há ≥ min_horas_uteis.'),
  ('O5', 'Viabilidade ok + endereço livre', true, 30, 50, '{"min_horas_uteis": 1}',
   'Viabilidade ok e endereço livre (portal/DFV), ainda sem venda, parado há ≥ min_horas_uteis.')
on conflict (codigo) do nothing;

-- ─────────────────────────────────────────────────────────────── 2. log
create table if not exists public.oportunidades_log (
  id          bigserial primary key,
  parceiro_id text not null default 'dharma',
  conversa_id uuid not null references public.mari_conversas(id) on delete cascade,
  codigo      text,
  tipo        text not null check (tipo in ('mostrada', 'enviada', 'dispensada', 'respondeu_24h', 'qualificou', 'pedido')),
  motivo      text,
  assumiu     boolean,
  canal       text,
  valor_mes   numeric,
  pontos      integer,
  detalhe     jsonb not null default '{}'::jsonb,
  criado_por  uuid default auth.uid(),
  criado_em   timestamptz not null default now()
);
create index if not exists oportunidades_log_conv_idx on public.oportunidades_log (conversa_id, criado_em desc);
create index if not exists oportunidades_log_tipo_idx on public.oportunidades_log (tipo, criado_em desc);
alter table public.oportunidades_log enable row level security;
drop policy if exists oportunidades_log_ler on public.oportunidades_log;
create policy oportunidades_log_ler on public.oportunidades_log for select to authenticated
  using (coalesce(public.meu_perfil(), '') in ('admin', 'backoffice'));
revoke all on public.oportunidades_log from anon;
grant select on public.oportunidades_log to authenticated;

-- ─────────────────────────────────────────────────────────────── 3. textos sugeridos
insert into public.config_mari_textos (chave, texto) values
  ('op_O1', 'Oi[, {nome}]! Aqui é {agente}, da Dharma, parceira Nio 😊 Vi que você estava vendo a fibra da Nio[ em {cidade}] com a Mari. Ficou alguma dúvida que eu possa resolver agora?'),
  ('op_O2', 'Oi[, {nome}]! Aqui é {agente}, da Dharma, parceira Nio 😊 Vi que você olhou os planos[ — o {plano} sai por R$ {valor}/mês, com preço fixo até 2030]. Qual deles faz mais sentido pra sua casa?'),
  ('op_O3', 'Oi[, {nome}]! Aqui é {agente}, da Dharma, parceira Nio. Entendo querer pensar com calma 😊 O preço da Nio é o da tabela, igual pra todo mundo, e fica fixo até 2030. Posso te ajudar a escolher o plano que cabe melhor no seu bolso?'),
  ('op_O4', 'Oi[, {nome}]! Aqui é {agente}, da Dharma, parceira Nio 😊 Falta pouquinho pra fechar seu pedido[ do {plano}]. Posso seguir com você agora pra terminar?'),
  ('op_O5', 'Oi[, {nome}]! Aqui é {agente}, da Dharma, parceira Nio 😊 Boa notícia: seu endereço[ em {cidade}] tem fibra Nio disponível. Quer que eu te mostre os planos e já deixe seu pedido encaminhado?')
on conflict (chave) do nothing;

-- Troca {var}; trecho entre [ ] some inteiro se alguma variável dele estiver vazia.
create or replace function public._oport_texto(p_txt text, p_vars jsonb)
returns text language plpgsql immutable set search_path = public as $$
declare
  r   text := coalesce(p_txt, '');
  m   text[];
  seg text;
  ok  boolean;
  k   text;
  i   int := 0;
begin
  loop
    m := regexp_match(r, '\[([^\[\]]*)\]');
    exit when m is null or i > 20;
    i := i + 1;
    seg := m[1];
    ok := true;
    for k in select (regexp_matches(seg, '\{(\w+)\}', 'g'))[1] loop
      if nullif(btrim(coalesce(p_vars ->> k, '')), '') is null then ok := false; end if;
    end loop;
    r := replace(r, '[' || seg || ']', case when ok then seg else '' end);
  end loop;
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    r := replace(r, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;
  return btrim(regexp_replace(regexp_replace(r, '\{\w+\}', '', 'g'), '\s{2,}', ' ', 'g'));
end $$;

-- Valor do mês: plano escolhido (cartão quando a forma é cartão) ou, sem plano, o mais barato da tabela do cliente.
create or replace function public._oport_plano(p_plano text, p_forma text, p_cluster text, p_segmento text)
returns table (plano text, valor numeric) language sql stable set search_path = public as $$
  select coalesce(p.nome_curto, p.nome),
         case when p_forma = 'cartao' then coalesce(p.preco_cartao, p.preco) else p.preco end
    from public.config_planos p where p.codigo = p_plano
  union all
  select coalesce(p.nome_curto, p.nome), p.preco
    from public.config_planos p
   where p_plano is null and p.ativo and p.cluster = p_cluster
     and (case when p_segmento = 'empresas' then 'MEI' else 'PF' end) = any (coalesce(p.segmentos, '{}'::text[]))
  order by 2 limit 1;
$$;

-- "há 4 h" · "35 min" · "2 d"
create or replace function public._oport_dur(p interval)
returns text language sql immutable as $$
  select case when p is null then '' when p < interval '1 hour' then greatest(extract(epoch from p)::int / 60, 1) || ' min'
              when p < interval '48 hours' then (extract(epoch from p)::int / 3600) || ' h'
              else (extract(epoch from p)::int / 86400) || ' d' end;
$$;

create or replace function public._oport_reais(v numeric)
returns text language sql immutable as $$
  select case when v is null then null when v = trunc(v) then trunc(v)::text else replace(to_char(v, 'FM99990.00'), '.', ',') end;
$$;

-- ─────────────────────────────────────────────────────────────── 4. v_oportunidades
create or replace view public.v_oportunidades with (security_invoker = true) as
with cfg as (
  select coalesce((g.p ->> 'ligado')::boolean, true)           as ligado,
         coalesce((g.p ->> 'max_dia')::int, 5)                  as max_dia,
         coalesce((g.p ->> 'max_por_conversa_dia')::int, 1)     as max_conv,
         coalesce((g.p ->> 'max_parado_dias')::numeric, 7)      as max_dias,
         coalesce((g.p ->> 'janela_horas')::numeric, 23)        as janela_h,
         g.p ->> 'template'                                     as tpl,
         (now() at time zone 'America/Sao_Paulo')::date         as hoje
    from (select coalesce((select parametros from public.config_oportunidades where codigo = 'geral'), '{}'::jsonb) as p) g
), regra as (
  select codigo, nome, pontos, ordem, parametros as p from public.config_oportunidades where ativo and codigo <> 'geral'
), tpl as (
  select t.nome from public.config_templates_waba t, cfg where t.nome = cfg.tpl and t.status = 'APPROVED'
), feitas_hoje as (
  select l.conversa_id, count(*) as n
    from public.oportunidades_log l, cfg
   where l.tipo in ('enviada', 'dispensada') and (l.criado_em at time zone 'America/Sao_Paulo')::date = cfg.hoje
   group by l.conversa_id
), eu as (
  select nullif(split_part(btrim(u.nome), ' ', 1), '') as nome from public.usuarios u where u.id = auth.uid()
), base as (
  select q.id as conversa_id, q.nome, q.cidade, q.cluster, q.segmento, q.coluna, q.plano_escolhido, q.plano_nome,
         q.itens_validados, q.itens_total, q.alertas, q.trava_viabilidade, q.trava_endereco_nio,
         q.ultima_em as parado_desde, c.ultima_msg_lead_at, c.forma_pagamento, c.dados, c.chatwoot_conversation_id,
         coalesce(nullif(split_part(btrim(c.dados ->> 'nome'), ' ', 1), ''),
                  case when c.nome_confiavel then nullif(split_part(btrim(c.nome_contato), ' ', 1), '') end) as primeiro_nome,
         public.mari_cadencia_nome(c) as nome_template,
         c.ultima_msg_lead_at + cfg.janela_h * interval '1 hour' as janela_fecha_em,
         public.minutos_uteis(q.ultima_em, now(), q.cidade) as min_uteis,
         exists (select 1 from public.mari_turnos t where t.conversa_id = q.id and t.papel = 'mari' and t.tags ? 'carrossel') as viu_planos
    from public.v_mari_quadro q
    join public.mari_conversas c on c.id = q.id
    cross join cfg
   where cfg.ligado
     and not q.teste
     and q.coluna in ('novo', 'qualificando', 'planos', 'dados', 'retomada')
     and q.vez = 'cliente' and coalesce(q.ultima_quem, '') <> 'humano'
     and q.venda_id is null
     and c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
     and not coalesce(c.nao_contatar, false) and not coalesce(c.humano_atribuido, false) and c.chatwoot_agente is null
     and (c.espera_ate is null or c.espera_ate <= now())
     and q.trava_cliente_nio <> 'bloqueia' and q.trava_viabilidade <> 'bloqueia' and q.trava_endereco_nio <> 'bloqueia'
     and q.ultima_em > now() - cfg.max_dias * interval '1 day'
     and coalesce((select f.n from feitas_hoje f where f.conversa_id = q.id), 0) < cfg.max_conv
     and not exists (select 1 from public.oportunidades_log l
                      where l.conversa_id = q.id and l.tipo = 'enviada' and l.criado_em > coalesce(c.ultima_msg_lead_at, '-infinity'::timestamptz))
), bate as (
  select b.*, r.codigo, r.pontos, r.ordem
    from base b
    join regra r on case r.codigo
      when 'O1' then b.janela_fecha_em > now()
                 and b.janela_fecha_em <= now() + coalesce((r.p ->> 'fecha_em_horas')::numeric, 4) * interval '1 hour'
                 and (b.itens_validados >= coalesce((r.p ->> 'termometro_min')::int, 2) or b.viu_planos or b.coluna = 'planos')
      when 'O2' then b.coluna = 'planos'
                 and b.min_uteis >= coalesce((r.p ->> 'min_horas_uteis')::numeric, 2) * 60
                 and b.parado_desde >= now() - coalesce((r.p ->> 'max_horas')::numeric, 48) * interval '1 hour'
      when 'O3' then ((b.dados ->> 'objecao') in (select jsonb_array_elements_text(coalesce(r.p -> 'objecoes', '[]'::jsonb)))
                      or b.alertas && array(select jsonb_array_elements_text(coalesce(r.p -> 'alertas', '[]'::jsonb))))
                 and b.min_uteis >= coalesce((r.p ->> 'min_horas_uteis')::numeric, 1) * 60
      when 'O4' then b.itens_validados >= coalesce((r.p ->> 'termometro_min')::int, 6)
                 and b.min_uteis >= coalesce((r.p ->> 'min_horas_uteis')::numeric, 1) * 60
      when 'O5' then b.trava_viabilidade = 'ok' and b.trava_endereco_nio = 'ok'
                 and b.min_uteis >= coalesce((r.p ->> 'min_horas_uteis')::numeric, 1) * 60
      else false end
), agg as (
  select conversa_id,
         (array_agg(codigo order by pontos desc, ordem))[1] as codigo,
         array_agg(codigo order by pontos desc, ordem) as regras,
         sum(pontos)::int as pontos
    from bate group by conversa_id
), linha as (
  select a.conversa_id, a.codigo, a.regras, a.pontos, b.nome, b.primeiro_nome, b.nome_template, b.cidade, b.coluna,
         b.parado_desde, b.janela_fecha_em, b.chatwoot_conversation_id, b.itens_validados, b.itens_total,
         coalesce(b.plano_nome, pv.plano) as plano, pv.valor as valor_mes,
         case
           when b.janela_fecha_em > now() then 'livre'
           when exists (select 1 from tpl) then 'template'
         end as canal,
         (select t.nome from tpl t) as template,
         case a.codigo
           when 'O1' then 'Janela de 24 h fecha em ' || public._oport_dur(b.janela_fecha_em - now())
                          || case when b.coluna = 'planos' or b.viu_planos then ' · já viu os planos' else '' end
           when 'O2' then 'Viu os planos há ' || public._oport_dur(now() - b.parado_desde) || ' e não escolheu'
           when 'O3' then case when 'desconto' = any (b.alertas) then 'Pediu desconto'
                               else 'Objeção: ' || coalesce(case b.dados ->> 'objecao' when 'preco' then 'achou caro' when 'pensar' then 'vai pensar'
                                    when 'consultar_alguem' then 'vai ver com alguém' when 'ja_tem' then 'já tem internet'
                                    when 'marca' then 'não conhece a Nio' when 'sem_5g' then 'não precisa do 5G' end, b.dados ->> 'objecao') end
                          || ' · sem resposta há ' || public._oport_dur(now() - b.parado_desde)
           when 'O4' then 'Quase pronto: ' || b.itens_validados || '/' || b.itens_total || ' dados · parou há ' || public._oport_dur(now() - b.parado_desde)
           when 'O5' then 'Viabilidade ok e endereço livre · parou há ' || public._oport_dur(now() - b.parado_desde)
         end
         || case when a.codigo <> 'O1' and 'O1' = any (a.regras) then ' · janela fecha em ' || public._oport_dur(b.janela_fecha_em - now()) else '' end
         as motivo
    from agg a
    join base b on b.conversa_id = a.conversa_id
    left join lateral public._oport_plano(b.plano_escolhido, b.forma_pagamento, b.cluster, b.segmento) pv on true
), numerada as (
  select l.*, row_number() over (order by l.pontos desc, l.janela_fecha_em nulls last, l.parado_desde) as n
    from linha l where l.canal is not null
)
select 'dharma'::text as parceiro_id, n.conversa_id, n.codigo, n.regras, n.pontos, n.nome, n.cidade, n.coluna, n.motivo,
       n.plano, n.valor_mes, n.janela_fecha_em, n.canal, n.template, n.parado_desde, n.chatwoot_conversation_id,
       case n.canal
         when 'livre' then public._oport_texto((select x.texto from public.config_mari_textos x where x.chave = 'op_' || n.codigo),
              jsonb_build_object('nome', n.primeiro_nome, 'cidade', n.cidade, 'plano', n.plano, 'valor', public._oport_reais(n.valor_mes),
                                 'agente', coalesce((select eu.nome from eu), 'o time')))
         when 'template' then public.mari_render_template(n.template, jsonb_build_array(n.nome_template))
       end as texto_sugerido,
       n.n as ordem
  from numerada n, cfg
 where n.n <= greatest(cfg.max_dia - coalesce((select sum(f.n) from feitas_hoje f), 0), 0);

grant select on public.v_oportunidades to authenticated;
revoke all on public.v_oportunidades from anon;

-- ─────────────────────────────────────────────────────────────── 5. enviar / dispensar
create or replace function public.oportunidade_enviar(p_conversa uuid, p_texto text, p_assumir boolean default false, p_template text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o        record;
  c        public.mari_conversas;
  g        uuid := gen_random_uuid();
  quem     text;
  txt      text := btrim(coalesce(p_texto, ''));
  ult_lead timestamptz;
  v_tpl    public.config_templates_waba;
  v_pay    jsonb;
  v_nome   text;
  aid      bigint;
  r        jsonb;
  agora_t  text := to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI');
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice manda mensagem pelo NIOGEN.' using errcode = '42501';
  end if;
  select * into o from public.v_oportunidades where conversa_id = p_conversa;
  if not found then
    raise exception 'Esta oportunidade não está mais aberta (o cliente respondeu, alguém já mandou ou a janela fechou). Atualize a tela.';
  end if;
  select nome into quem from public.usuarios where id = auth.uid();
  quem := coalesce(nullif(split_part(btrim(quem), ' ', 1), ''), 'time');

  if coalesce(p_assumir, false) then
    -- Mandar e assumir: o caminho de sempre da caixa do NIOGEN (atribui, a Mari cala, a cadência para).
    r := public.backoffice_responder(p_conversa, txt, false, p_template);
  else
    select * into c from public.mari_conversas where id = p_conversa for update;
    if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Esta conversa não está no Chatwoot.'; end if;
    if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
    if coalesce(c.nao_contatar, false) then raise exception 'O cliente pediu para não ser contatado.'; end if;
    if p_template is null and txt = '' then raise exception 'Escreva a mensagem.'; end if;
    if length(txt) > 4000 then raise exception 'Mensagem longa demais (máx. 4.000 caracteres).'; end if;
    select max(t.created_at) into ult_lead from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead';
    if p_template is not null then
      select * into v_tpl from public.config_templates_waba where nome = p_template and status = 'APPROVED' and nome like 'nio\_%';
      if v_tpl.nome is null then raise exception 'Template não aprovado: %', p_template; end if;
      if (select count(*) from regexp_matches(coalesce(v_tpl.corpo, ''), '\{\{[0-9]+\}\}', 'g')) > 1 then
        raise exception 'Este template precisa de mais dados; mande pelo Chatwoot.';
      end if;
      v_nome := public.mari_cadencia_nome(c);
      v_pay := jsonb_build_object('content', public.mari_render_template(v_tpl.nome, jsonb_build_array(v_nome)), 'content_type', 'text',
        'message_type', 'outgoing', 'private', false, 'template', v_tpl.nome,
        'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
          'processed_params', jsonb_build_object('body', jsonb_build_object('1', v_nome))));
    else
      -- Janela de 24 h é regra do WhatsApp: fechada → só template.
      if ult_lead is null or now() >= ult_lead + interval '23 hours' then
        raise exception 'A janela de 24 h fechou: só template aprovado.' using errcode = 'P0001';
      end if;
      v_pay := jsonb_build_object('content', txt, 'message_type', 'outgoing', 'private', false);
    end if;
    v_pay := v_pay || jsonb_build_object('como', 'humano', 'conta', 'sim', 'rotulo', 'oportunidade 🔥', 'oportunidade', o.codigo);
    aid := public._bo_enfileirar(g, 1, 'oportunidade', c.venda_id, c, 'mensagem', v_pay);
    perform public._bo_enfileirar(g, 2, 'oportunidade', c.venda_id, c, 'nota',
      jsonb_build_object('content', '🔥 Esquentada por ' || quem || ' às ' || agora_t || ' (' || coalesce(o.motivo, o.codigo) || ') — a Mari segue.'));
    -- Depois do eco: se o Chatwoot deixar a conversa com dono, ela volta para a Mari (sem dono = a Mari responde).
    perform public._bo_enfileirar(g, 3, 'oportunidade', c.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[🔥 esquentada no NIOGEN por ' || quem || ' — a Mari segue]', false);
    r := jsonb_build_object('ok', true, 'acao_id', aid, 'assumiu', false, 'resumo', '✓ mensagem enviada · a Mari segue a conversa');
  end if;

  insert into public.oportunidades_log (conversa_id, codigo, tipo, motivo, assumiu, canal, valor_mes, pontos, detalhe)
  values (p_conversa, o.codigo, 'enviada', o.motivo, coalesce(p_assumir, false), case when p_template is null then 'livre' else 'template' end,
          o.valor_mes, o.pontos,
          jsonb_strip_nulls(jsonb_build_object('regras', to_jsonb(o.regras), 'template', p_template,
            'editado', case when p_template is null then txt is distinct from btrim(coalesce(o.texto_sugerido, '')) end,
            'acao_id', r ->> 'acao_id')));
  return r || jsonb_build_object('oportunidade', o.codigo);
end $$;
revoke all on function public.oportunidade_enviar(uuid, text, boolean, text) from public, anon;
grant execute on function public.oportunidade_enviar(uuid, text, boolean, text) to authenticated;

create or replace function public.oportunidade_dispensar(p_conversa uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o record;
  ok boolean;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select exists (select 1 from public.config_oportunidades g, jsonb_array_elements(coalesce(g.parametros -> 'dispensa_motivos', '[]'::jsonb)) m
                  where g.codigo = 'geral' and m ->> 'codigo' = p_motivo) into ok;
  if not ok then raise exception 'Motivo desconhecido: %', p_motivo; end if;
  select * into o from public.v_oportunidades where conversa_id = p_conversa;
  insert into public.oportunidades_log (conversa_id, codigo, tipo, motivo, valor_mes, pontos, detalhe)
  values (p_conversa, o.codigo, 'dispensada', p_motivo, o.valor_mes, o.pontos, jsonb_strip_nulls(jsonb_build_object('regras', to_jsonb(o.regras))));
  return jsonb_build_object('ok', true, 'resumo', 'Some até amanhã');
end $$;
revoke all on function public.oportunidade_dispensar(uuid, text) from public, anon;
grant execute on function public.oportunidade_dispensar(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────── 6. mostrada + resultados (idempotente)
create or replace function public.oportunidades_atualizar()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  n_m int; n_r int; n_q int; n_p int;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return jsonb_build_object('ok', false); end if;
  insert into public.oportunidades_log (conversa_id, codigo, tipo, motivo, canal, valor_mes, pontos, detalhe, criado_por)
  select o.conversa_id, o.codigo, 'mostrada', o.motivo, o.canal, o.valor_mes, o.pontos, jsonb_build_object('regras', to_jsonb(o.regras)), null
    from public.v_oportunidades o
   where not exists (select 1 from public.oportunidades_log l where l.conversa_id = o.conversa_id and l.tipo = 'mostrada'
                       and (l.criado_em at time zone 'America/Sao_Paulo')::date = hoje);
  get diagnostics n_m = row_count;
  -- Resultado de cada mensagem enviada (últimos 30 dias): respondeu em 24 h · qualificou · pedido.
  insert into public.oportunidades_log (conversa_id, codigo, tipo, detalhe, criado_por, criado_em)
  select e.conversa_id, e.codigo, 'respondeu_24h', jsonb_build_object('enviada_id', e.id), null, t.em
    from public.oportunidades_log e
    cross join lateral (select min(t.created_at) as em from public.mari_turnos t
                         where t.conversa_id = e.conversa_id and t.papel = 'lead' and t.created_at > e.criado_em
                           and t.created_at <= e.criado_em + interval '24 hours') t
   where e.tipo = 'enviada' and e.criado_em > now() - interval '30 days' and t.em is not null
     and not exists (select 1 from public.oportunidades_log x where x.tipo = 'respondeu_24h' and x.detalhe ->> 'enviada_id' = e.id::text);
  get diagnostics n_r = row_count;
  insert into public.oportunidades_log (conversa_id, codigo, tipo, detalhe, criado_por, criado_em)
  select e.conversa_id, e.codigo, 'qualificou', jsonb_build_object('enviada_id', e.id), null, coalesce(c.handoff_em, now())
    from public.oportunidades_log e join public.mari_conversas c on c.id = e.conversa_id
   where e.tipo = 'enviada' and e.criado_em > now() - interval '30 days'
     and ((c.handoff_motivo = 'dados_completos' and c.handoff_em > e.criado_em) or c.venda_id is not null)
     and not exists (select 1 from public.oportunidades_log x where x.tipo = 'qualificou' and x.detalhe ->> 'enviada_id' = e.id::text);
  get diagnostics n_q = row_count;
  insert into public.oportunidades_log (conversa_id, codigo, tipo, detalhe, criado_por)
  select e.conversa_id, e.codigo, 'pedido', jsonb_build_object('enviada_id', e.id, 'venda_id', v.id), null
    from public.oportunidades_log e join public.mari_conversas c on c.id = e.conversa_id join public.vendas v on v.id = c.venda_id
   where e.tipo = 'enviada' and e.criado_em > now() - interval '60 days' and coalesce(v.nio_pedido, '') <> ''
     and not exists (select 1 from public.oportunidades_log x where x.tipo = 'pedido' and x.detalhe ->> 'enviada_id' = e.id::text);
  get diagnostics n_p = row_count;
  return jsonb_build_object('ok', true, 'mostradas', n_m, 'responderam', n_r, 'qualificaram', n_q, 'pedidos', n_p);
end $$;
revoke all on function public.oportunidades_atualizar() from public, anon;
grant execute on function public.oportunidades_atualizar() to authenticated;

-- ─────────────────────────────────────────────────────────────── 9. resumo (Painel)
create or replace function public.oportunidades_resumo(p_dias int default 7)
returns jsonb language sql stable security invoker set search_path = public as $$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
  l as (select x.*, (x.criado_em at time zone 'America/Sao_Paulo')::date as dia from public.oportunidades_log x),
  conta as (
    select case when l.dia = (select d from hoje) then 'hoje' end as faixa, l.tipo, l.conversa_id from l
     where l.dia = (select d from hoje)
    union all
    select 'periodo', l.tipo, l.conversa_id from l where l.dia > (select d from hoje) - greatest(p_dias, 1)
  ),
  -- Controle: mostradas que NÃO tiveram mensagem nossa no dia — o cliente respondeu em 24 h mesmo assim?
  controle as (
    select count(*) as n,
           count(*) filter (where exists (select 1 from public.mari_turnos t where t.conversa_id = m.conversa_id and t.papel = 'lead'
                                            and t.created_at > m.criado_em and t.created_at <= m.criado_em + interval '24 hours')) as responderam
      from l m
     where m.tipo = 'mostrada' and m.dia > (select d from hoje) - greatest(p_dias, 1)
       and not exists (select 1 from l e where e.tipo = 'enviada' and e.conversa_id = m.conversa_id and e.dia = m.dia)
  )
  select jsonb_build_object(
    'hoje', (select jsonb_build_object(
      'mostradas', count(distinct conversa_id) filter (where tipo = 'mostrada'),
      'enviadas', count(*) filter (where tipo = 'enviada'),
      'dispensadas', count(*) filter (where tipo = 'dispensada'),
      'responderam', count(*) filter (where tipo = 'respondeu_24h'),
      'qualificaram', count(*) filter (where tipo = 'qualificou'),
      'pedidos', count(*) filter (where tipo = 'pedido')) from conta where faixa = 'hoje'),
    'periodo', (select jsonb_build_object(
      'dias', greatest(p_dias, 1),
      'mostradas', count(*) filter (where tipo = 'mostrada'),
      'enviadas', count(*) filter (where tipo = 'enviada'),
      'dispensadas', count(*) filter (where tipo = 'dispensada'),
      'responderam', count(*) filter (where tipo = 'respondeu_24h'),
      'qualificaram', count(*) filter (where tipo = 'qualificou'),
      'pedidos', count(*) filter (where tipo = 'pedido')) from conta where faixa = 'periodo'),
    'controle', (select jsonb_build_object('sem_mensagem', n, 'responderam', responderam) from controle));
$$;
revoke all on function public.oportunidades_resumo(int) from public, anon;
grant execute on function public.oportunidades_resumo(int) to authenticated;

-- ─────────────────────────────────────────────────────────────── 8. feed
create or replace view public.v_mari_feed with (security_invoker = true) as
with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
conv as (
  select c.id, c.cidade, c.origem, c.created_at,
         coalesce(nullif(split_part(btrim(c.dados ->> 'nome'), ' ', 1), ''), nullif(split_part(btrim(c.nome_contato), ' ', 1), ''), 'Contato') as nome
    from public.mari_conversas c
   where c.canal <> 'teste' and coalesce(c.telefone, '') not like '5500000000%'
),
ev as (
  -- lead novo
  select c.created_at as em, c.id as conversa_id, c.nome, 'lead'::text as tipo,
         'lead novo · ' || coalesce(case c.origem when 'meta_ads' then 'anúncio' when 'instagram' then 'Instagram' when 'facebook' then 'Facebook'
           when 'site' then 'site' when 'fila_vero' then 'Fila Vero' when 'indicacao' then 'indicação' when 'direto' then 'WhatsApp direto' end, 'WhatsApp')
         || coalesce(' · ' || c.cidade, '') as texto, 'ok'::text as nivel
    from conv c where (c.created_at at time zone 'America/Sao_Paulo')::date = (select d from hoje)
  union all
  -- o que a Mari fez (pelos marcadores do turno — nunca a fala)
  select t.created_at, t.conversa_id, c.nome, x.tipo, x.texto, x.nivel
    from public.mari_turnos t
    join conv c on c.id = t.conversa_id
    cross join lateral (values
      ('planos',   case when t.tags ? 'carrossel' then 'mostrou os planos' end, 'ok'),
      ('plano',    case when t.tags ? 'plano_escolhido' then 'escolheu o plano ' || coalesce((select coalesce(p.nome_curto, p.nome) from public.config_planos p where p.codigo = t.tags ->> 'plano_escolhido'), t.tags ->> 'plano_escolhido') end, 'ok'),
      ('eleg',     case t.tags ->> 'elegibilidade' when 'ok' then 'confirmou que não é cliente Nio' when 'fora_area' then 'fora da área de atuação' when 'ja_cliente' then 'já é cliente Nio' when 'cancelou_30d' then 'cancelou a Nio há menos de 30 dias' end,
                   case when t.tags ->> 'elegibilidade' = 'ok' then 'ok' else 'warn' end),
      ('endereco', case when t.tags ? 'endereco' then 'endereço confirmado' end, 'ok'),
      ('toque',    case when t.tags ? 'cadencia' then 'toque ' || (t.tags ->> 'cadencia') || ' enviado' end, 'info'),
      ('handoff',  case when t.tags ? 'handoff' then 'passou a conversa para o time' end, 'ok'),
      ('caindo',   case when t.tags ->> 'avaliacao' = 'interesse_caindo' then 'interesse caindo' end, 'warn')
    ) as x(tipo, texto, nivel)
   where t.papel = 'mari' and jsonb_typeof(t.tags) = 'object' and x.texto is not null
     and (t.created_at at time zone 'America/Sao_Paulo')::date = (select d from hoje)
  union all
  -- objeção do cliente (só o tipo, nunca a fala)
  select t.created_at, t.conversa_id, c.nome, 'objecao',
         case when t.texto ~* 'descont|mais barat|faz (um |por )?menos' then 'pediu desconto'
              when t.texto ~* '\mcar[oa]\M|pesad[oa] (pra|para)|fora do (meu )?or[cç]amento' then 'achou caro'
              when t.texto ~* 'vou pensar|deixa eu pensar|pensar melhor' then 'vai pensar'
              else 'vai ver com alguém' end, 'warn'
    from public.mari_turnos t join conv c on c.id = t.conversa_id
   where t.papel = 'lead' and (t.created_at at time zone 'America/Sao_Paulo')::date = (select d from hoje)
     and t.texto ~* '(descont|mais barat|faz (um |por )?menos|\mcar[oa]\M|pesad[oa] (pra|para)|fora do (meu )?or[cç]amento|vou pensar|deixa eu pensar|pensar melhor|ver com (o |a |meu |minha )?(marido|esposa|mulher|fam[ií]lia|pai|m[aã]e))'
  union all
  -- oportunidades
  select l.criado_em, l.conversa_id, c.nome, 'oportunidade',
         case l.tipo when 'mostrada' then '🔥 virou oportunidade → Live'
                     when 'enviada' then '🔥 mensagem do time' || case when l.assumiu then ' · assumiu' else ' · a Mari segue' end
                     when 'respondeu_24h' then '🔥 respondeu à mensagem do time'
                     when 'qualificou' then '🔥 qualificou depois da mensagem do time'
                     when 'pedido' then '🔥 virou pedido' end, 'fire'
    from public.oportunidades_log l join conv c on c.id = l.conversa_id
   where l.tipo <> 'dispensada' and (l.criado_em at time zone 'America/Sao_Paulo')::date = (select d from hoje)
  union all
  -- erros do motor
  select e.created_at, e.conversa_id, coalesce(c.nome, '—'), 'erro', 'erro no turno' || coalesce(' · ' || e.no_n8n, ''), 'bad'
    from public.mari_erros e left join conv c on c.id = e.conversa_id
   where (e.created_at at time zone 'America/Sao_Paulo')::date = (select d from hoje)
     and (e.conversa_id is null or c.id is not null)
)
select 'dharma'::text as parceiro_id, em, conversa_id, nome, tipo, texto, nivel
  from ev order by em desc limit 30;
grant select on public.v_mari_feed to authenticated;
revoke all on public.v_mari_feed from anon;

-- ─────────────────────────────────────────────────────────────── 7. pulso + funil de resultado
create or replace function public.mari_ao_vivo()
returns jsonb language plpgsql stable security definer set search_path = public as $$
-- security definer: usa a base do Agente de Tráfego (só service/definer); a porta é o perfil admin/backoffice, conferido abaixo.
declare
  hoje      date := (now() at time zone 'America/Sao_Paulo')::date;
  ini       timestamptz := ((now() at time zone 'America/Sao_Paulo')::date)::timestamp at time zone 'America/Sao_Paulo';
  v_ult     timestamptz;
  v_agora   int;
  v_media   numeric;
  v_toques  int;
  v_sem     int;
  v_erros   int;
  v_waba    text;
  v_horario boolean;
  v_estado  text;
  v_prox    jsonb;
  v_funil   jsonb;
  v_planos  int;
  v_vendas  int;
  v_ritmo   jsonb;
  v_neg     jsonb;
  v_oport   int;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select max(t.created_at) into v_ult
    from public.mari_turnos t join public.mari_conversas c on c.id = t.conversa_id
   where t.papel = 'mari' and c.canal <> 'teste' and coalesce(c.telefone, '') not like '5500000000%';
  select count(distinct c.id) into v_agora
    from public.mari_conversas c
   where c.canal <> 'teste' and coalesce(c.telefone, '') not like '5500000000%'
     and (c.processando_ate > now()
          or exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'mari' and t.created_at > now() - interval '2 minutes'));
  -- Tempo de resposta: da fala do cliente até a 1ª resposta da Mari (até 30 min), hoje.
  select round(avg(extract(epoch from (r.em - l.created_at)))) into v_media
    from public.mari_turnos l
    join public.mari_conversas c on c.id = l.conversa_id
    cross join lateral (select min(t.created_at) as em from public.mari_turnos t
                         where t.conversa_id = l.conversa_id and t.papel = 'mari' and t.created_at > l.created_at
                           and t.created_at <= l.created_at + interval '30 minutes' and not (coalesce(t.tags, '{}'::jsonb) ? 'cadencia')) r
   where l.papel = 'lead' and l.created_at >= ini and r.em is not null
     and c.canal <> 'teste' and coalesce(c.telefone, '') not like '5500000000%'
     and not exists (select 1 from public.mari_turnos l2 where l2.conversa_id = l.conversa_id and l2.papel = 'lead'
                      and l2.created_at > l.created_at and l2.created_at < r.em);
  select count(*) into v_toques
    from public.mari_turnos t join public.mari_conversas c on c.id = t.conversa_id
   where t.papel = 'mari' and t.created_at >= ini and jsonb_typeof(t.tags) = 'object' and t.tags ? 'cadencia'
     and c.canal <> 'teste' and coalesce(c.telefone, '') not like '5500000000%';
  select count(*) into v_sem from public.v_mari_sem_resposta;
  select count(*) into v_erros from public.mari_erros where created_at >= ini;
  select w.quality_rating into v_waba from public.waba_qualidade w order by w.lida_em desc nulls last limit 1;
  v_horario := public.mari_no_horario(now(), null);
  v_estado := case when v_sem > 0 then 'parada'
                   when v_ult is not null and v_ult > now() - interval '10 minutes' then 'ativa'
                   when not v_horario then 'quieta'
                   else 'ativa' end;
  select jsonb_build_object('nome', split_part(btrim(coalesce(q.nome, 'Contato')), ' ', 1), 'passo', q.proximo_passo,
                            'em', coalesce(q.proximo_toque_em, q.proximo_em))
    into v_prox
    from public.v_mari_quadro q
   where not q.teste and q.coluna <> 'encerrada' and q.proximo_passo is not null and coalesce(q.proximo_toque_em, q.proximo_em) is not null
   order by coalesce(q.proximo_toque_em, q.proximo_em) limit 1;

  -- Funil de resultado do dia: a mesma base do Agente de Tráfego (conversas abertas hoje) + "viram os planos".
  select jsonb_build_object('conversas', coalesce(sum(b.conversas), 0), 'responderam', coalesce(sum(b.responderam), 0),
                            'cep_valido', coalesce(sum(b.cep_valido_area), 0), 'qualificadas', coalesce(sum(b.qualificadas), 0))
    into v_funil from public.agente_trafego_funil(1) b where b.dia = hoje;
  select count(*) into v_planos
    from public.mari_conversas c
   where c.created_at >= ini and c.canal <> 'teste' and coalesce(c.telefone, '') not like '5500000000%'
     and (c.plano_escolhido is not null or c.etapa in ('coleta', 'resumo') or c.handoff_motivo = 'dados_completos'
          or exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'mari' and t.tags ? 'carrossel'));
  select count(*) into v_vendas from public.vendas v
   where v.criado_em >= date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'
     and coalesce(v.status, '') <> 'saida';
  v_ritmo := public.painel_meta_ritmo(hoje);
  -- Em negociação: conversas abertas (sem venda) com plano escolhido ou que já viram os planos — R$ por mês.
  select jsonb_build_object('valor', coalesce(sum(pv.valor), 0), 'conversas', count(*))
    into v_neg
    from public.v_mari_quadro q
    join public.mari_conversas c on c.id = q.id
    left join lateral public._oport_plano(q.plano_escolhido, c.forma_pagamento, q.cluster, q.segmento) pv on true
   where not q.teste and q.venda_id is null and q.coluna not in ('encerrada')
     and (q.plano_escolhido is not null or q.coluna in ('planos', 'dados', 'completo'));
  select count(*) into v_oport from public.v_oportunidades;

  return jsonb_build_object(
    'estado', v_estado, 'no_horario', v_horario, 'ultimo_turno_em', v_ult, 'respondendo_agora', v_agora,
    'resposta_media_s', v_media, 'proximo_toque', v_prox, 'toques_hoje', v_toques, 'sem_resposta', v_sem,
    'erros_hoje', v_erros, 'waba_qualidade', v_waba,
    'funil', coalesce(v_funil, '{}'::jsonb) || jsonb_build_object('viram_planos', v_planos, 'vendas_mes', v_vendas,
              'instaladas_mes', v_ritmo -> 'instaladas', 'meta', v_ritmo -> 'meta'),
    'em_negociacao', v_neg, 'oportunidades', v_oport, 'gerado_em', now());
end $$;
revoke all on function public.mari_ao_vivo() from public, anon;
grant execute on function public.mari_ao_vivo() to authenticated;
