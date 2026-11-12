-- NIOGEN | supabase/migrations/0147_destino_unico_conversa.sql | 12/11/2026 — Claude Code (Opus 5.5)
-- Prompt "Destino único de cada conversa", Fase 2 — definições aprovadas pelo Ricardo em 12/11 ("Aprovo as 6") + pedido de travas:
-- "Não fazemos atendimento por dentro do Chatwoot, apenas por dentro do Niogen, portanto ele precisa de guardrails".
-- Diagnóstico: docs/DIAGNOSTICO_destino_conversas_121126_1528.md (Drive).
--
-- O quê:
--   1. config_funil — as 11 etapas e os 10 destinos (nome, ordem, etiqueta do Chatwoot), em config (regra 15).
--   2. mari_conversas.funil_* — etapa (a mais alta alcançada, nunca volta), destino (um só), detalhe, quando, alerta.
--   3. funil_eventos — toda troca de destino e toda ação feita FORA do NIOGEN (auditoria + medida de 7 dias).
--   4. Gatilho antes (mari_conversas): calcula etapa e destino. Saída "dura" (teste, instalada, já cliente, fora de área,
--      sem cobertura, não contatar) vale sempre; saída "de evento" (saída da venda, Saída da conversa, handoff de recusa,
--      cadência esgotada) vale quando acontece e fica até o cliente voltar a escrever — aí reabre na mesma etapa.
--   5. Gatilho depois: toda saída põe a etiqueta saida-<destino> e resolve no Chatwoot (pela fila chatwoot_acoes);
--      reabriu → tira a etiqueta. Exceção: suporte Nio silenciado (fica adiado com o time, para a Mari não responder).
--   6. Gatilho em vendas: mudança de status/saída/pedido/biometria/agendamento/instalação recalcula a conversa.
--   7. Travas: (a) "Resolver" pelo NIOGEN só com destino de saída; (b) Saída da conversa aceita os destinos canônicos;
--      (c) conversa resolvida direto no Chatwoot sem destino → alerta "resolvida_fora_niogen"; (d) fala de pessoa digitada
--      direto no Chatwoot (sem passar pela fila do NIOGEN) → alerta "mensagem_fora_niogen". Alertas aparecem na v_conversas.
--   8. Retrato do Agente de Tráfego: tira os telefones de teste, biometria "validada", qualificadas_reais, por_destino, por_etapa.
--   9. Backfill de todas as conversas (o gatilho depois enfileira etiqueta + resolve das saídas ainda abertas).
-- parceiro_id em tudo que é novo (regra 15). Nada de dado pessoal no retrato.

-- ───────────────────────── 1. config ─────────────────────────
create table if not exists public.config_funil (
  parceiro_id text not null default 'dharma',
  tipo        text not null check (tipo in ('etapa', 'destino')),
  codigo      text not null,
  nome        text not null,
  ordem       int  not null,
  saida       boolean not null default false,
  etiqueta    text,
  primary key (parceiro_id, tipo, codigo)
);
alter table public.config_funil enable row level security;
drop policy if exists config_funil_ler on public.config_funil;
create policy config_funil_ler on public.config_funil for select to authenticated using (true);
revoke all on public.config_funil from anon;
grant select on public.config_funil to authenticated;
grant all on public.config_funil to service_role;

insert into public.config_funil (tipo, codigo, nome, ordem, saida, etiqueta) values
  ('etapa', 'nova',        'Nova',               1, false, null),
  ('etapa', 'respondeu',   'Respondeu',          2, false, null),
  ('etapa', 'cep',         'CEP',                3, false, null),
  ('etapa', 'area_ok',     'Área ok',            4, false, null),
  ('etapa', 'viavel',      'Viável',             5, false, null),
  ('etapa', 'viu_planos',  'Viu os planos',      6, false, null),
  ('etapa', 'qualificada', 'Qualificada',        7, false, null),
  ('etapa', 'pedido',      'Pedido',             8, false, null),
  ('etapa', 'biometria',   'Biometria',          9, false, null),
  ('etapa', 'agendada',    'Agendada',          10, false, null),
  ('etapa', 'instalada',   'Instalada',         11, false, null),
  ('destino', 'em_andamento',        'Em andamento',           0, false, null),
  ('destino', 'instalada',           'Instalada',              1, true,  'saida-instalada'),
  ('destino', 'reprovado_biometria', 'Reprovado na biometria', 2, true,  'saida-biometria'),
  ('destino', 'credito_negado',      'Crédito negado',         3, true,  'saida-credito'),
  ('destino', 'ja_cliente_nio',      'Já é cliente Nio',       4, true,  'saida-ja-cliente'),
  ('destino', 'fora_area',           'Fora da área',           5, true,  'saida-fora-area'),
  ('destino', 'sem_cobertura',       'Sem cobertura',          6, true,  'saida-sem-cobertura'),
  ('destino', 'recusou',             'Recusou',                7, true,  'saida-recusou'),
  ('destino', 'sem_resposta',        'Sem resposta',           8, true,  'saida-sem-resposta'),
  ('destino', 'teste_duplicada',     'Teste ou duplicada',     9, true,  null)
on conflict (parceiro_id, tipo, codigo) do update
  set nome = excluded.nome, ordem = excluded.ordem, saida = excluded.saida, etiqueta = excluded.etiqueta;
comment on table public.config_funil is
  'Etapas (escada, nunca volta) e destinos (um só por conversa) do funil da Mari. Etiqueta = a do Chatwoot posta na saída. 0147.';

-- ───────────────────────── 2. colunas ─────────────────────────
alter table public.mari_conversas
  add column if not exists funil_etapa       text,
  add column if not exists funil_destino     text,
  add column if not exists funil_detalhe     text,
  add column if not exists funil_destino_em  timestamptz,
  add column if not exists funil_evento      text,          -- transitório: quem quer forçar o recálculo grava aqui; o gatilho zera
  add column if not exists funil_alerta      text,
  add column if not exists funil_alerta_em   timestamptz;
alter table public.mari_conversas drop constraint if exists mari_conversas_funil_etapa_check;
alter table public.mari_conversas add constraint mari_conversas_funil_etapa_check check (funil_etapa is null or funil_etapa in
  ('nova', 'respondeu', 'cep', 'area_ok', 'viavel', 'viu_planos', 'qualificada', 'pedido', 'biometria', 'agendada', 'instalada'));
alter table public.mari_conversas drop constraint if exists mari_conversas_funil_destino_check;
alter table public.mari_conversas add constraint mari_conversas_funil_destino_check check (funil_destino is null or funil_destino in
  ('em_andamento', 'instalada', 'reprovado_biometria', 'credito_negado', 'ja_cliente_nio', 'fora_area', 'sem_cobertura',
   'recusou', 'sem_resposta', 'teste_duplicada'));
alter table public.mari_conversas drop constraint if exists mari_conversas_funil_alerta_check;
alter table public.mari_conversas add constraint mari_conversas_funil_alerta_check check (funil_alerta is null or funil_alerta in
  ('resolvida_fora_niogen', 'mensagem_fora_niogen'));
create index if not exists mari_conversas_funil_destino_idx on public.mari_conversas (funil_destino);
create index if not exists mari_conversas_funil_alerta_idx on public.mari_conversas (funil_alerta_em desc) where funil_alerta is not null;
comment on column public.mari_conversas.funil_etapa is 'Etapa mais alta alcançada (config_funil tipo etapa). Nunca volta. 0147.';
comment on column public.mari_conversas.funil_destino is 'Destino único (config_funil tipo destino). Saída de evento fica até o cliente voltar a escrever. 0147.';
comment on column public.mari_conversas.funil_alerta is 'Ação feita fora do NIOGEN (resolvida ou mensagem direto no Chatwoot). Some quando o destino é registrado no NIOGEN. 0147.';

-- ───────────────────────── 3. eventos ─────────────────────────
create table if not exists public.funil_eventos (
  id          bigserial primary key,
  parceiro_id text not null default 'dharma',
  conversa_id uuid references public.mari_conversas(id) on delete cascade,
  em          timestamptz not null default now(),
  tipo        text not null check (tipo in ('destino', 'etapa', 'alerta')),
  de          text,
  para        text,
  detalhe     text,
  por         uuid
);
create index if not exists funil_eventos_conversa_idx on public.funil_eventos (conversa_id, em desc);
create index if not exists funil_eventos_em_idx on public.funil_eventos (em desc);
alter table public.funil_eventos enable row level security;
drop policy if exists funil_eventos_ler on public.funil_eventos;
create policy funil_eventos_ler on public.funil_eventos for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.funil_eventos from anon, authenticated;
grant select on public.funil_eventos to authenticated;
grant all on public.funil_eventos to service_role;
grant usage, select on sequence public.funil_eventos_id_seq to service_role;

-- ───────────────────────── 4. regras ─────────────────────────
-- Motivo de saída da venda (texto livre do front, MOTIVOS_SAIDA / conferência) → destino canônico.
create or replace function public.funil_destino_de_motivo(p_motivo text)
returns text language sql immutable set search_path = public as $$
  select case
    when p_motivo is null or btrim(p_motivo) = '' then 'recusou'
    when lower(p_motivo) ~ 'biometria' then 'reprovado_biometria'
    when lower(p_motivo) ~ 'cr[eé]dito' then 'credito_negado'
    when lower(p_motivo) ~ '(cliente nio|pedido na nio|cancelou a nio)' then 'ja_cliente_nio'
    when lower(p_motivo) ~ 'fora d[ae] [aá]rea' then 'fora_area'
    when lower(p_motivo) ~ 'cobertura' then 'sem_cobertura'
    when lower(p_motivo) ~ '(sem contato|n[aã]o atende)' then 'sem_resposta'
    when lower(p_motivo) ~ '(duplic|teste)' then 'teste_duplicada'
    else 'recusou'   -- Desistiu, Preço, Concorrente, Interesse futuro, não confirmou, dados divergentes, fraude, outro
  end
$$;

-- Saída da conversa (backoffice_conversa_saida / quadro_encerrada_motivo) → destino. Nomes antigos mapeados.
create or replace function public._funil_destino_quadro(p text)
returns text language sql immutable set search_path = public as $$
  select case p
    when 'perdida' then 'recusou' when 'ja_cliente' then 'ja_cliente_nio' when 'suporte_nio' then 'ja_cliente_nio'
    when 'fora_area' then 'fora_area' when 'sem_cobertura' then 'sem_cobertura' when 'recusou' then 'recusou'
    when 'credito_negado' then 'credito_negado' when 'sem_resposta' then 'sem_resposta' when 'teste_duplicada' then 'teste_duplicada'
    when 'ja_cliente_nio' then 'ja_cliente_nio' end
$$;

-- Handoff da Mari → destino (só os que são saída; pedido_humano e multiplos_decisores são estado de atendimento).
create or replace function public._funil_destino_handoff(p text)
returns text language sql immutable set search_path = public as $$
  select case p
    when 'fora_de_area' then 'fora_area' when 'sem_cobertura' then 'sem_cobertura' when 'recusa_compra' then 'recusou'
    when 'ja_cliente_nio' then 'ja_cliente_nio' when 'sem_contato' then 'sem_resposta' end
$$;

create or replace function public._funil_ordem(p_tipo text, p_codigo text)
returns int language sql stable set search_path = public as $$
  select coalesce((select ordem from public.config_funil where parceiro_id = 'dharma' and tipo = p_tipo and codigo = p_codigo), 0)
$$;

-- Etapa e destinos calculados de uma conversa (sem efeito colateral).
--   duro    = saída que vale sempre que o dado está lá
--   evento  = saída que vale quando acontece (venda em saída, Saída da conversa, handoff de recusa, cadência esgotada)
create or replace function public._funil_calcular(c public.mari_conversas)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v        public.vendas;
  tel      text := regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g');
  teste    boolean;
  viavel   boolean; viav_pend boolean; cliente boolean;
  pedido   boolean; bio boolean; agendada boolean; instalada boolean; qualif boolean; viu boolean;
  respondeu boolean := false;
  etapa    text;
  duro     text; duro_det text;
  evento   text; evento_det text;
  quadro   text := public._funil_destino_quadro(c.quadro_encerrada_motivo);
  hand     text := public._funil_destino_handoff(c.handoff_motivo);
begin
  if c.venda_id is not null then select * into v from public.vendas where id = c.venda_id; end if;
  teste := coalesce(c.canal, '') = 'teste' or tel like '5500000000%'
        or tel = any (coalesce((select array_remove(regexp_split_to_array(regexp_replace(coalesce(texto, ''), '[^0-9,]', '', 'g'), ','), '')
                                  from public.config_mari_textos where chave = 'telefones_teste'), '{}'::text[]));
  viavel    := coalesce(c.cobertura_decisao in ('viavel', 'elegivel_200m') or c.nio_viab_resultado = 'viavel' or v.nio_viab_resultado = 'viavel', false);
  viav_pend := coalesce(c.cobertura_decisao = 'unidade_fora_lista', false);       -- decisão 1: viável com pendência (não qualifica sozinha)
  pedido    := coalesce(v.nio_pedido is not null or v.nio_os is not null
            or v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'), false);
  cliente   := coalesce(c.elegibilidade = 'ja_cliente' or c.handoff_motivo = 'ja_cliente_nio' or c.quadro_encerrada_motivo = 'suporte_nio'
            or ((c.credito_resultado = 'pedido_em_andamento' or c.nio_pedido_aberto = 'sim') and not pedido), false);  -- decisões 2 e 3
  bio       := v.biometria_status = 'validada';
  agendada  := v.instalacao_agendada_para is not null or v.status in ('2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  instalada := v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  viu       := c.plano_escolhido is not null or c.etapa in ('planos', 'coleta', 'resumo') or c.handoff_motivo = 'dados_completos' or v.id is not null;
  qualif    := coalesce(c.handoff_motivo = 'dados_completos' or v.id is not null, false) and viavel and not cliente
            and coalesce(c.credito_resultado, '') not like 'negado%' and coalesce(v.motivo_saida, '') !~* 'cr[eé]dito';
  if c.id is not null and c.ultima_msg_lead_at is not null and coalesce(c.funil_etapa, 'nova') = 'nova' then
    select count(*) >= 2 into respondeu from (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' limit 2) x;
  end if;

  etapa := case
    when coalesce(instalada, false) then 'instalada'
    when coalesce(agendada, false)  then 'agendada'
    when coalesce(bio, false)       then 'biometria'
    when coalesce(pedido, false)    then 'pedido'
    when coalesce(qualif, false)    then 'qualificada'
    when coalesce(viu, false)       then 'viu_planos'
    when coalesce(viavel or viav_pend, false) then 'viavel'
    when c.dentro_area is true      then 'area_ok'
    when c.cep is not null          then 'cep'
    when respondeu or coalesce(c.funil_etapa, 'nova') <> 'nova' then 'respondeu'
    else 'nova' end;

  -- saída dura (na ordem de prioridade)
  if teste then duro := 'teste_duplicada'; duro_det := 'telefone ou canal de teste';
  elsif coalesce(instalada, false) then duro := 'instalada'; duro_det := 'instalada';
  elsif cliente then duro := 'ja_cliente_nio';
    duro_det := case when c.quadro_encerrada_motivo = 'suporte_nio' then 'suporte Nio'
                     when c.elegibilidade = 'ja_cliente' or c.handoff_motivo = 'ja_cliente_nio' then 'elegibilidade: já cliente'
                     else 'pedido Nio em andamento (não é nosso)' end;
  elsif c.dentro_area is false or c.elegibilidade = 'fora_area' then duro := 'fora_area'; duro_det := 'CEP fora da área';
  elsif c.cobertura_decisao = 'sem_cobertura' or c.nio_viab_resultado = 'sem_viabilidade' then duro := 'sem_cobertura'; duro_det := 'viabilidade: sem cobertura';
  elsif coalesce(c.nao_contatar, false) then duro := 'recusou'; duro_det := 'não contatar';
  end if;

  -- saída de evento: cada fonte em separado (o gatilho só aplica a fonte que acabou de mudar) + a primeira pela prioridade
  return jsonb_build_object('etapa', etapa, 'duro', duro, 'duro_det', duro_det,
    'venda',   case when v.status = 'saida' then public.funil_destino_de_motivo(v.motivo_saida) end,
    'venda_det', 'venda: ' || coalesce(v.motivo_saida, 'sem motivo'),
    'quadro',  quadro, 'quadro_det', 'Saída da conversa: ' || c.quadro_encerrada_motivo,
    'hand',    hand,   'hand_det', 'Mari: ' || c.handoff_motivo,
    'cad',     case when c.cadencia_passo = 'encerrada' then 'sem_resposta' end, 'cad_det', 'cadência esgotada',
    'evento',  coalesce(case when v.status = 'saida' then public.funil_destino_de_motivo(v.motivo_saida) end, quadro, hand,
                        case when c.cadencia_passo = 'encerrada' then 'sem_resposta' end),
    'evento_det', case when v.status = 'saida' then 'venda: ' || coalesce(v.motivo_saida, 'sem motivo')
                       when quadro is not null then 'Saída da conversa: ' || c.quadro_encerrada_motivo
                       when hand is not null then 'Mari: ' || c.handoff_motivo
                       when c.cadencia_passo = 'encerrada' then 'cadência esgotada' end);
end;
$$;

-- ───────────────────────── 5. gatilho antes ─────────────────────────
create or replace function public._funil_antes()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  d        jsonb;
  ev       text;
  novo     text; det text;
  ant      text := coalesce(new.funil_destino, 'em_andamento');
  saida_ev boolean;
begin
  d := public._funil_calcular(new);
  -- etapa: só sobe
  if new.funil_etapa is null or public._funil_ordem('etapa', d ->> 'etapa') > public._funil_ordem('etapa', new.funil_etapa) then
    new.funil_etapa := d ->> 'etapa';
  end if;

  -- qual fonte de evento acabou de mudar (só ela vale: um sinal velho não derruba uma conversa que o cliente reabriu)
  ev := case
    when new.funil_evento = 'venda' and d ->> 'venda' is not null then 'venda'
    when tg_op = 'UPDATE' and new.quadro_encerrada_motivo is distinct from old.quadro_encerrada_motivo and d ->> 'quadro' is not null then 'quadro'
    when tg_op = 'UPDATE' and new.handoff_motivo is distinct from old.handoff_motivo and d ->> 'hand' is not null then 'hand'
    when tg_op = 'UPDATE' and new.cadencia_passo is distinct from old.cadencia_passo and d ->> 'cad' is not null then 'cad' end;
  saida_ev := ant not in ('em_andamento', 'teste_duplicada', 'instalada');

  if d ->> 'duro' is not null and (ev is null
      or public._funil_ordem('destino', d ->> 'duro') <= public._funil_ordem('destino', d ->> ev)) then
    novo := d ->> 'duro'; det := d ->> 'duro_det';
  elsif ev is not null then
    novo := d ->> ev; det := d ->> (ev || '_det');
  elsif new.funil_evento = 'reabrir' then
    novo := 'em_andamento'; det := 'venda reativada';
  elsif tg_op = 'UPDATE' and old.funil_destino is not null and ant in ('teste_duplicada', 'instalada') then
    novo := 'em_andamento'; det := 'saída dura não vale mais';
  elsif saida_ev and new.ultima_msg_lead_at is not null and new.funil_destino_em is not null
        and new.ultima_msg_lead_at > new.funil_destino_em then
    novo := 'em_andamento'; det := 'cliente voltou a escrever';          -- reabre na mesma etapa
  elsif tg_op = 'UPDATE' and old.funil_destino is not null then
    novo := old.funil_destino; det := old.funil_detalhe;                 -- saída de evento fica
  else
    novo := coalesce(d ->> 'evento', 'em_andamento'); det := d ->> 'evento_det';   -- 1º cálculo (backfill / conversa nova)
  end if;

  if novo is distinct from new.funil_destino then
    new.funil_destino := novo;
    new.funil_detalhe := det;
    new.funil_destino_em := now();
    if novo <> 'em_andamento' then new.funil_alerta := null; new.funil_alerta_em := null; end if;   -- destino registrado: alerta some
  end if;
  new.funil_evento := null;
  return new;
exception when others then
  -- o funil nunca derruba a gravação da conversa: registra e segue sem recalcular
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (new.id, 'funil_antes', sqlerrm);
  new.funil_evento := null;
  return new;
end;
$$;
drop trigger if exists mari_conversas_funil_antes on public.mari_conversas;
create trigger mari_conversas_funil_antes before insert or update on public.mari_conversas
  for each row execute function public._funil_antes();

-- ───────────────────────── 6. gatilho depois: Chatwoot ─────────────────────────
create or replace function public._funil_depois()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  g     uuid := gen_random_uuid();
  lab   text;
  todas jsonb;
  tem_cw boolean := coalesce(new.chatwoot_conversation_id, '') <> '' and coalesce(new.telefone, '') not like '5500000000%'
                    and coalesce(new.canal, '') = 'whatsapp';
  ja_resolve boolean;
begin
  if tg_op = 'UPDATE' and new.funil_destino is not distinct from old.funil_destino then
    if new.funil_etapa is distinct from old.funil_etapa then
      insert into public.funil_eventos (conversa_id, tipo, de, para) values (new.id, 'etapa', old.funil_etapa, new.funil_etapa);
    end if;
    return null;
  end if;
  insert into public.funil_eventos (conversa_id, tipo, de, para, detalhe, por)
  values (new.id, 'destino', case when tg_op = 'UPDATE' then old.funil_destino end, new.funil_destino, new.funil_detalhe, auth.uid());

  if not tem_cw or new.funil_destino = 'teste_duplicada' then return null; end if;
  select coalesce(jsonb_agg(etiqueta), '[]'::jsonb) into todas from public.config_funil
   where parceiro_id = 'dharma' and tipo = 'destino' and etiqueta is not null;

  if new.funil_destino = 'em_andamento' then
    if tg_op = 'UPDATE' and old.funil_destino not in ('em_andamento', 'teste_duplicada') then
      perform public._bo_enfileirar(g, 1, 'destino', new.venda_id, new, 'etiquetas', jsonb_build_object('add', '[]'::jsonb, 'remove', todas));
    end if;
    return null;
  end if;

  select etiqueta into lab from public.config_funil where parceiro_id = 'dharma' and tipo = 'destino' and codigo = new.funil_destino;
  if lab is not null then
    perform public._bo_enfileirar(g, 1, 'destino', new.venda_id, new, 'etiquetas',
      jsonb_build_object('add', jsonb_build_array(lab), 'remove', todas - lab));
  end if;
  -- instalada não resolve (o pós-venda segue na conversa); suporte Nio silenciado fica adiado com o time (a Mari não responde)
  if new.funil_destino = 'instalada' or new.quadro_encerrada_motivo = 'suporte_nio' then return null; end if;
  select exists (select 1 from public.chatwoot_acoes a where a.conversa_id = new.id and a.tipo = 'resolver'
                   and a.payload ->> 'status' = 'resolved' and a.criada_em > now() - interval '5 minutes'
                   and a.status in ('pendente', 'executando', 'feita')) into ja_resolve;
  if not ja_resolve and coalesce(new.chatwoot_status, 'open') <> 'resolved' then
    perform public._bo_enfileirar(g, 2, 'destino', new.venda_id, new, 'resolver', jsonb_build_object('status', 'resolved'));
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_funil_depois', sqlerrm);
  return null;
end;
$$;
drop trigger if exists mari_conversas_funil_depois on public.mari_conversas;
create trigger mari_conversas_funil_depois after insert or update on public.mari_conversas
  for each row execute function public._funil_depois();

-- ───────────────────────── 7. gatilho em vendas ─────────────────────────
create or replace function public._funil_venda_mudou()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status or new.motivo_saida is distinct from old.motivo_saida
     or new.nio_pedido is distinct from old.nio_pedido or new.nio_os is distinct from old.nio_os
     or new.biometria_status is distinct from old.biometria_status
     or new.instalacao_agendada_para is distinct from old.instalacao_agendada_para
     or new.instalado_em is distinct from old.instalado_em or new.nio_viab_resultado is distinct from old.nio_viab_resultado then
    update public.mari_conversas
       set funil_evento = case when old.status = 'saida' and new.status <> 'saida' then 'reabrir'
                               when new.status = 'saida' and (old.status is distinct from 'saida' or new.motivo_saida is distinct from old.motivo_saida) then 'venda'
                               else 'recalc' end
     where venda_id = new.id;
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_funil_venda_mudou', sqlerrm);
  return null;
end;
$$;
drop trigger if exists vendas_funil on public.vendas;
create trigger vendas_funil after update on public.vendas for each row execute function public._funil_venda_mudou();

-- ───────────────────────── 8. travas ─────────────────────────
-- (c) Resolvida no Chatwoot: se não veio de um botão do NIOGEN e a conversa não tem destino de saída → alerta.
create or replace function public.mari_encerrar_ciclo(p_chatwoot_conversation_id text)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_id uuid;
  u    public.mari_conversas;
begin
  if coalesce(btrim(p_chatwoot_conversation_id), '') = '' then
    return jsonb_build_object('ok', false, 'erro', 'conversa do Chatwoot vazia');
  end if;
  -- 0147: trava "não se atende pelo Chatwoot"
  select * into u from public.mari_conversas
   where canal = 'whatsapp' and chatwoot_conversation_id = btrim(p_chatwoot_conversation_id)
   order by updated_at desc limit 1;
  if found and coalesce(u.funil_destino, 'em_andamento') = 'em_andamento'
     and not exists (select 1 from public.chatwoot_acoes a
                      where a.chatwoot_conversation_id = btrim(p_chatwoot_conversation_id) and a.tipo = 'resolver'
                        and a.criada_em > now() - interval '30 minutes') then
    update public.mari_conversas set funil_alerta = 'resolvida_fora_niogen', funil_alerta_em = now() where id = u.id;
    insert into public.funil_eventos (conversa_id, tipo, para, detalhe)
    values (u.id, 'alerta', 'resolvida_fora_niogen', 'resolvida direto no Chatwoot sem destino');
  end if;

  select id into v_id from public.mari_conversas
   where canal = 'whatsapp' and chatwoot_conversation_id = btrim(p_chatwoot_conversation_id)
     and status = 'handoff_realizado'
   order by updated_at desc limit 1;
  if v_id is null then
    return jsonb_build_object('ok', true, 'fechado', false, 'motivo', 'nenhuma conversa da Mari em handoff com esse id');
  end if;
  return public._mari_fechar_ciclo(v_id, 'conversa resolvida no Chatwoot');
end;
$$;

-- (d) Fala de pessoa digitada direto no Chatwoot: a detecção da 0102 (_resposta_fora_niogen: sem item na outbox do NIOGEN)
--     passa a acender também o alerta da conversa.
create or replace function public._resposta_fora_niogen()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  c    public.mari_conversas;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if exists (select 1 from public.chatwoot_acoes a
              where a.conversa_id = new.conversa_id and a.tipo in ('mensagem', 'nota')
                and a.status in ('pendente', 'executando', 'feita')
                and a.momento <> 'resposta_fora_niogen'   -- a própria nota do aviso não conta como resposta pelo NIOGEN
                and (a.criada_em >= new.created_at - interval '5 minutes'
                     or (a.payload ->> 'content' = new.texto and a.criada_em >= new.created_at - interval '6 hours'))) then
    return null;
  end if;
  select * into c from public.mari_conversas where id = new.conversa_id;
  if not found or c.canal <> 'whatsapp' or coalesce(c.telefone, '') like '5500000000%' then return null; end if;
  insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
  values (c.id, 'resposta_fora_niogen', 'Fala do time chegou pelo Chatwoot sem passar pelo NIOGEN',
          jsonb_build_object('turno_id', new.id, 'texto', left(coalesce(new.texto, ''), 200)));
  -- 0147: a trava aparece na conversa (v_conversas.funil_alerta) e no rastro do funil
  update public.mari_conversas set funil_alerta = 'mensagem_fora_niogen', funil_alerta_em = now() where id = c.id;
  insert into public.funil_eventos (conversa_id, tipo, para, detalhe)
  values (c.id, 'alerta', 'mensagem_fora_niogen', 'fala de pessoa digitada direto no Chatwoot');
  if coalesce(c.chatwoot_conversation_id, '') <> ''
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.momento = 'resposta_fora_niogen'
                       and (a.criada_em at time zone 'America/Sao_Paulo')::date = hoje) then
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'resposta_fora_niogen', c.venda_id, c, 'nota',
      jsonb_build_object('content', 'Respondido pelo Chatwoot — responda pelo NIOGEN para a venda andar.'));
  end if;
  return null;
exception when others then
  return null;   -- o rastro nunca derruba a gravação da conversa
end;
$$;

-- (a) "Resolver" pelo NIOGEN só com destino de saída; reabrir continua livre.
create or replace function public.backoffice_conversa(p_conversa uuid, p_acao text, p_valor text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c      public.mari_conversas;
  g      uuid := gen_random_uuid();
  v_time int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  lab    text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa;
  if not found or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Conversa sem Chatwoot.'; end if;
  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
  if p_acao = 'atribuir' then
    if p_valor = 'eu' then return public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', c.id)); end if;
    if p_valor = 'mari' then return public.backoffice_momento(null, 'devolver_mari', jsonb_build_object('conversa_id', c.id)); end if;
    if p_valor = 'time' then
      perform public.mari_cadencia_parar(c.id, p_time => true);
      perform public._bo_enfileirar(g, 1, 'atribuir', c.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 2, 'atribuir', c.venda_id, c, 'atribuir', jsonb_build_object('team_id', v_time));
      return jsonb_build_object('ok', true, 'resumo', '✓ conversa no time backoffice (a Mari calou)');
    end if;
    raise exception 'Atribuição inválida.';
  elsif p_acao = 'status' then
    if p_valor not in ('open', 'resolved') then raise exception 'Status inválido.'; end if;
    if p_valor = 'resolved' and coalesce(c.funil_destino, 'em_andamento') in ('em_andamento', 'instalada') then
      raise exception 'Para resolver, registre o destino: ficha da conversa → Saída (ou Saída da venda). Conversa sem destino não se resolve.';
    end if;
    perform public._bo_enfileirar(g, 1, 'status', c.venda_id, c, 'resolver', jsonb_build_object('status', p_valor));
    return jsonb_build_object('ok', true, 'resumo', case when p_valor = 'resolved' then '✓ conversa resolvida' else '✓ conversa reaberta' end);
  elsif p_acao in ('etiqueta_add', 'etiqueta_remove') then
    lab := lower(btrim(coalesce(p_valor, '')));
    if lab !~ '^[a-z0-9_-]{2,40}$' then raise exception 'Etiqueta inválida.'; end if;
    if lab like 'saida-%' then raise exception 'Etiqueta de saída é do NIOGEN: registre o destino pela Saída.'; end if;
    perform public._bo_enfileirar(g, 1, 'etiqueta', c.venda_id, c, 'etiquetas',
      case when p_acao = 'etiqueta_add' then jsonb_build_object('add', jsonb_build_array(lab))
           else jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array(lab)) end);
    return jsonb_build_object('ok', true, 'resumo', case when p_acao = 'etiqueta_add' then '✓ etiqueta ' || lab || ' posta' else '✓ etiqueta ' || lab || ' tirada' end);
  end if;
  raise exception 'Ação desconhecida: %', p_acao;
end;
$$;
grant execute on function public.backoffice_conversa(uuid, text, text) to authenticated;

-- (b) Saída da conversa aceita os destinos canônicos (0126 + nomes novos; o resolve passa a sair pelo gatilho do funil).
CREATE OR REPLACE FUNCTION public.backoffice_conversa_saida(p_conversa uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.mari_conversas;
  g       uuid := gen_random_uuid();
  v_time  int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  quem    text;
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
  nomes   jsonb := '{"perdida": "Recusou", "recusou": "Recusou", "fora_area": "Fora da área", "ja_cliente": "Já é cliente Nio", "ja_cliente_nio": "Já é cliente Nio", "sem_cobertura": "Sem cobertura", "credito_negado": "Crédito negado", "sem_resposta": "Sem resposta", "teste_duplicada": "Teste ou duplicada"}'::jsonb;  -- 0147: destinos canônicos (perdida/ja_cliente = nomes antigos)
  tem_cw  boolean;
  feito   text[] := '{}';
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null and p_motivo <> 'reativar' then
    raise exception 'Esta conversa já tem venda: use a Saída da venda.';
  end if;
  select nome into quem from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');
  tem_cw := coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%';

  if p_motivo = 'suporte_nio' then
    perform public.mari_cadencia_parar(c.id, p_time => true);
    update public.mari_conversas
       set quadro_encerrada_motivo = 'suporte_nio', quadro_encerrada_em = now(), quadro_encerrada_por = auth.uid(), processando_ate = null
     where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[silenciada no NIOGEN por ' || quem || ' — cliente Nio, suporte/reclamação: não é venda]', false);
    feito := feito || 'fora do Live (mesmo se ele escrever)'::text || 'cadência parada'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'silenciar', null, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('suporte-nio'), 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(g, 2, 'silenciar', null, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 3, 'silenciar', null, c, 'atribuir', jsonb_build_object('team_id', v_time));
      perform public._bo_enfileirar(g, 4, 'silenciar', null, c, 'nota', jsonb_build_object('content',
        '📵 Silenciada por ' || quem || ' em ' || agora_t || ': cliente Nio com suporte/reclamação — não é venda (somos revenda, '
        || 'não o suporte da Nio). Canal da Nio: App Nio ou 0800. A Mari não responde e a conversa não volta para o Live (fica em Conversas › Todas, com o selo 📵). '
        || 'Para desfazer: ficha da conversa no NIOGEN → Reativar.'));
      perform public._bo_enfileirar(g, 5, 'silenciar', null, c, 'resolver', jsonb_build_object('status', 'snoozed'));
      feito := feito || 'etiqueta suporte-nio'::text || 'time backoffice (a Mari cala)'::text || 'nota'::text || 'adiada no Chatwoot'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito),
      'resumo', '✓ silenciada: a Mari não responde e ela não volta para o Live');

  elsif p_motivo = 'reativar' then
    if coalesce(c.quadro_encerrada_motivo, '') <> 'suporte_nio' then
      return jsonb_build_object('ok', true, 'feito', '[]'::jsonb, 'resumo', 'A conversa não estava silenciada.');
    end if;
    update public.mari_conversas set quadro_encerrada_motivo = null, quadro_encerrada_em = null, quadro_encerrada_por = null where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[reativada no NIOGEN por ' || quem || ']', false);
    feito := feito || 'de volta no Live'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'reativar', null, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('suporte-nio')));
      perform public._bo_enfileirar(g, 2, 'reativar', null, c, 'nota',
        jsonb_build_object('content', '🔔 Reativada por ' || quem || ' em ' || agora_t || ' — segue com o time; para a Mari voltar, "Devolver para a Mari".'));
      feito := feito || 'etiqueta tirada'::text || 'nota'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ reativada: segue com o time backoffice');

  elsif nomes ? p_motivo then
    perform public.mari_cadencia_parar(c.id, p_resolvida => true);
    update public.mari_conversas
       set quadro_encerrada_motivo = p_motivo, quadro_encerrada_em = now(), quadro_encerrada_por = auth.uid(), processando_ate = null
     where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[encerrada no NIOGEN por ' || quem || ' — ' || (nomes ->> p_motivo) || ']', false);
    feito := feito || 'Saída'::text || 'cadência parada'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'saida', null, c, 'nota', jsonb_build_object('content',
        '⛔ Saída · ' || (nomes ->> p_motivo) || ' — ' || quem || ', ' || agora_t || '. Se o cliente escrever de novo, volta para o Live.'));
      -- 0147: etiqueta saida-<destino> e resolve saem pelo gatilho do funil (mari_conversas_funil_depois); teste resolve aqui
      if p_motivo = 'teste_duplicada' then
        perform public._bo_enfileirar(g, 2, 'saida', null, c, 'resolver', jsonb_build_object('status', 'resolved'));
      end if;
      feito := feito || 'nota'::text || 'etiqueta de saída'::text || 'conversa resolvida'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ Saída · ' || (nomes ->> p_motivo));
  end if;
  raise exception 'Motivo desconhecido: %', p_motivo;
end;
$function$;
grant execute on function public.backoffice_conversa_saida(uuid, text) to authenticated;

-- ───────────────────────── 9. view das telas ─────────────────────────
-- v_conversas (0143) + as colunas do funil no fim (a tela Conversas e a ficha leem daqui).
create or replace view public.v_conversas with (security_invoker=true) as
 SELECT c.id,
    c.venda_id,
    COALESCE(NULLIF(btrim((c.dados ->> 'nome'::text)), ''::text), NULLIF(btrim(c.nome_contato), ''::text), 'Contato'::text) AS nome,
    c.telefone,
    c.cidade,
    c.origem,
    c.chatwoot_conversation_id,
    c.chatwoot_status,
    COALESCE(c.chatwoot_etiquetas, '{}'::text[]) AS etiquetas,
        CASE
            WHEN COALESCE(c.nao_contatar, false) THEN NULL::text
            WHEN (c.chatwoot_agente IS NOT NULL) THEN 'pessoa'::text
            WHEN COALESCE(c.humano_atribuido, false) THEN 'pessoa'::text
            WHEN (c.chatwoot_status = 'resolved'::text) THEN NULL::text
            WHEN (c.chatwoot_time IS NOT NULL) THEN 'time'::text
            ELSE 'mari'::text
        END AS dono_tipo,
        CASE
            WHEN COALESCE(c.nao_contatar, false) THEN NULL::text
            WHEN (c.chatwoot_agente IS NOT NULL) THEN c.chatwoot_agente
            WHEN COALESCE(c.humano_atribuido, false) THEN 'time (assumida)'::text
            WHEN (c.chatwoot_status = 'resolved'::text) THEN NULL::text
            WHEN (c.chatwoot_time IS NOT NULL) THEN ('time '::text || c.chatwoot_time)
            ELSE 'Mari'::text
        END AS dono_nome,
    COALESCE(u.created_at, c.created_at) AS ultima_em,
    u.papel AS ultima_quem,
    "left"(regexp_replace(COALESCE(u.texto, ''::text), '\s+'::text, ' '::text, 'g'::text), 160) AS ultima_txt,
    ((l.ult_lead IS NOT NULL) AND (l.ult_lead > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone)) AND (l.ult_lead > (now() - '7 days'::interval)) AND (COALESCE(c.chatwoot_status, 'open'::text) <> ALL (ARRAY['resolved'::text, 'snoozed'::text])) AND (NOT ((c.espera_ate IS NOT NULL) AND (l.ult_lead <= c.espera_em))) AND (cliente_confirmou_desde(c.id, l.ult_resp) IS NULL)) AS cliente_esperando,
        CASE
            WHEN ((l.ult_lead IS NOT NULL) AND (l.ult_lead > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone)) AND (COALESCE(c.chatwoot_status, 'open'::text) <> ALL (ARRAY['resolved'::text, 'snoozed'::text])) AND (cliente_confirmou_desde(c.id, l.ult_resp) IS NULL)) THEN (floor((EXTRACT(epoch FROM (now() - l.ult_lead)) / (60)::numeric)))::integer
            ELSE NULL::integer
        END AS esperando_min,
    l.ult_lead,
    ((l.ult_lead IS NOT NULL) AND (l.ult_lead > (now() - '23:00:00'::interval))) AS janela_aberta,
        CASE
            WHEN (v.id IS NOT NULL) THEN jornada_etapa(v.status, v.nio_pedido, v.credito_resultado)
            ELSE 1
        END AS etapa,
    (COALESCE(c.nao_contatar, false) OR (c.status = ANY (ARRAY['encerrado_humano'::text, 'encerrado_ia'::text])) OR (COALESCE(v.status, ''::text) = 'saida'::text) OR (COALESCE(c.quadro_encerrada_motivo, ''::text) = 'suporte_nio'::text)) AS encerrada,
    c.created_at,
    'dharma'::text AS parceiro_id,
    c.funil_etapa,
    c.funil_destino,
    c.funil_detalhe,
    c.funil_destino_em,
    c.funil_alerta,
    c.funil_alerta_em
   FROM (((mari_conversas c
     LEFT JOIN vendas v ON ((v.id = c.venda_id)))
     CROSS JOIN LATERAL ( SELECT max(t.created_at) FILTER (WHERE (t.papel = 'lead'::text)) AS ult_lead,
            GREATEST(max(t.created_at) FILTER (WHERE (t.papel = ANY (ARRAY['mari'::text, 'humano'::text]))), c.dispensada_em) AS ult_resp
           FROM mari_turnos t
          WHERE (t.conversa_id = c.id)) l)
     LEFT JOIN LATERAL ( SELECT t.papel,
            t.texto,
            t.created_at
           FROM mari_turnos t
          WHERE ((t.conversa_id = c.id) AND (t.papel = ANY (ARRAY['lead'::text, 'mari'::text, 'humano'::text])))
          ORDER BY t.created_at DESC
         LIMIT 1) u ON (true))
  WHERE ((c.canal = 'whatsapp'::text) AND (COALESCE(c.telefone, ''::text) !~~ '5500000000%'::text));

-- ───────────────────────── 10. retrato do Agente de Tráfego (lê o destino único) ─────────────────────────
-- _agente_trafego_base ganha destino, etapa e qualificada_real (muda o retorno → drop). agente_trafego_funil segue igual (lê por nome).
drop function if exists public._agente_trafego_base(int);
create or replace function public._agente_trafego_base(p_dias int default 14)
returns table (
  parceiro_id text, dia date, origem text,
  campanha_id text, campanha_nome text, conjunto_id text, conjunto_nome text, ad_id text, ad_nome text,
  cidade text, cluster text,
  respondeu boolean, cep_informado boolean, cep_valido_area boolean, fora_area boolean, ja_cliente_nio boolean,
  sem_cobertura boolean, qualificada boolean, pedido_aberto boolean, biometria_aprovada boolean, instalada boolean,
  saida text, plano text, forma_pagamento text,
  destino text, etapa text, qualificada_real boolean
)
language sql stable security definer set search_path = public as $$
  with janela as (
    select ((now() at time zone 'America/Sao_Paulo')::date - (greatest(1, least(coalesce(p_dias, 14), 90)) - 1)) as de
  )
  select 'dharma'::text,
         (c.created_at at time zone 'America/Sao_Paulo')::date,
         case when r.ad_id is not null then 'meta_ads' else coalesce(nullif(c.origem, ''), 'direto') end,
         a.campanha_id, a.campanha_nome, a.adset_id, a.adset_nome, r.ad_id, a.ad_nome,
         coalesce(nullif(trim(c.cidade), ''), 'sem cidade'),
         coalesce(nullif(c.cluster, ''), 'sem cluster'),
         coalesce(t.lead_msgs, 0) >= 2,
         c.cep is not null,
         c.cep is not null and c.dentro_area is true,
         c.funil_destino = 'fora_area',                -- 0147: o destino único
         c.funil_destino = 'ja_cliente_nio',
         c.funil_destino = 'sem_cobertura',
         c.handoff_motivo = 'dados_completos',
         v.nio_pedido is not null
           or v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'),
         v.biometria_status in ('validada', 'aprovada'),   -- 0147: o banco grava 'validada'
         v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme'),
         nullif(c.funil_destino, 'em_andamento'),     -- 0147: uma saída por conversa, nome canônico
         nullif(c.plano_escolhido, ''),
         nullif(c.forma_pagamento, ''),
         coalesce(c.funil_destino, 'em_andamento'),
         coalesce(c.funil_etapa, 'nova'),
         c.funil_etapa in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')
           and coalesce(c.funil_destino, '') not in ('ja_cliente_nio', 'credito_negado', 'teste_duplicada')
    from public.mari_conversas c
    cross join janela j
    left join lateral (
      select count(*)::int as lead_msgs from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead'
    ) t on true
    left join lateral (
      select r.ad_id from public.meta_referrals r
       where r.telefone = c.telefone and r.ad_id is not null
         and r.recebido_em between c.created_at - interval '10 minutes' and c.created_at + interval '10 minutes'
         -- 0067: o clique é de UMA conversa só — a mais recente do telefone já aberta quando a mensagem do anúncio chegou
         and not exists (select 1 from public.mari_conversas c2
                          where c2.telefone = c.telefone and c2.created_at > c.created_at
                            and c2.created_at <= r.recebido_em + interval '2 minutes')
       order by r.recebido_em
       limit 1
    ) r on true
    left join public.meta_ads_anuncios a on a.ad_id = r.ad_id
    left join public.vendas v on v.id = c.venda_id
   where c.canal = 'whatsapp'
     and coalesce(c.funil_destino, '') <> 'teste_duplicada'   -- 0147: telefones de teste fora
     and (c.created_at at time zone 'America/Sao_Paulo')::date >= j.de
$$;
revoke execute on function public._agente_trafego_base(int) from public, anon, authenticated;
grant execute on function public._agente_trafego_base(int) to service_role;

create or replace function public.agente_trafego_retrato(p_dias int default 14)
returns jsonb language sql stable security definer set search_path = public as $$
  with
  par as (
    select greatest(1, least(coalesce(p_dias, 14), 90)) as dias,
           (now() at time zone 'America/Sao_Paulo')::date as ate
  ),
  jan as (select dias, ate, ate - (dias - 1) as de from par),
  base as (select * from public._agente_trafego_base((select dias from jan))),
  -- funil em vários recortes de uma vez; g_* diz qual recorte é a linha
  f as (
    select grouping(b.dia) = 0 as g_dia, grouping(b.ad_id) = 0 as g_ad, grouping(b.conjunto_id) = 0 as g_conj,
           grouping(b.cidade) = 0 as g_cid, grouping(b.origem) = 0 as g_ori,
           b.dia, b.ad_id, b.conjunto_id, b.cidade, b.origem,
           jsonb_build_object(
             'conversas', count(*), 'responderam', count(*) filter (where b.respondeu),
             'cep_informado', count(*) filter (where b.cep_informado), 'cep_valido_area', count(*) filter (where b.cep_valido_area),
             'fora_area', count(*) filter (where b.fora_area), 'ja_cliente_nio', count(*) filter (where b.ja_cliente_nio),
             'sem_cobertura', count(*) filter (where b.sem_cobertura), 'qualificadas', count(*) filter (where b.qualificada),
             'qualificadas_reais', count(*) filter (where b.qualificada_real),
             'por_destino', public._agente_trafego_contar(array_agg(b.destino)),
             'por_etapa', public._agente_trafego_contar(array_agg(b.etapa)),
             'pedidos_abertos', count(*) filter (where b.pedido_aberto), 'biometria_aprovada', count(*) filter (where b.biometria_aprovada),
             'instaladas', count(*) filter (where b.instalada),
             'saidas', public._agente_trafego_contar(array_agg(b.saida)),
             'plano_escolhido', public._agente_trafego_contar(array_agg(b.plano)),
             'forma_pagamento', public._agente_trafego_contar(array_agg(b.forma_pagamento))) as funil
      from base b
     group by grouping sets ((), (b.dia), (b.ad_id), (b.conjunto_id), (b.cidade), (b.origem))
  ),
  -- gasto da Meta nos mesmos recortes (dia, anúncio, conjunto, total)
  m as (
    select grouping(d.dia) = 0 as g_dia, grouping(d.ad_id) = 0 as g_ad, grouping(d.adset_id) = 0 as g_conj,
           d.dia, d.ad_id, d.adset_id,
           round(sum(d.gasto), 2) as gasto, sum(d.impressoes)::int as impressoes, sum(d.cliques)::int as cliques,
           sum(d.conversas)::int as conversas_meta
      from public.meta_ads_diario d, jan
     where d.dia between jan.de and jan.ate
     group by grouping sets ((), (d.dia), (d.ad_id), (d.adset_id))
  ),
  zero as (
    select jsonb_build_object('conversas', 0, 'responderam', 0, 'cep_informado', 0, 'cep_valido_area', 0, 'fora_area', 0,
                              'ja_cliente_nio', 0, 'sem_cobertura', 0, 'qualificadas', 0, 'qualificadas_reais', 0,
                              'por_destino', '{}'::jsonb, 'por_etapa', '{}'::jsonb, 'pedidos_abertos', 0,
                              'biometria_aprovada', 0, 'instaladas', 0, 'saidas', '{}'::jsonb,
                              'plano_escolhido', '{}'::jsonb, 'forma_pagamento', '{}'::jsonb) as z
  ),
  mt as (  -- total da Meta (sempre 1 linha)
    select coalesce((select gasto from m where not (g_dia or g_ad or g_conj)), 0) as gasto,
           coalesce((select impressoes from m where not (g_dia or g_ad or g_conj)), 0) as impressoes,
           coalesce((select cliques from m where not (g_dia or g_ad or g_conj)), 0) as cliques,
           coalesce((select conversas_meta from m where not (g_dia or g_ad or g_conj)), 0) as conversas_meta
  ),
  ft as (select coalesce((select funil from f where not (g_dia or g_ad or g_conj or g_cid or g_ori)), (select z from zero)) as funil),
  fm as (select coalesce((select funil from f where g_ori and origem = 'meta_ads'), (select z from zero)) as funil)
  select jsonb_build_object(
    'gerado_em', to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS"-03:00"'),
    'parceiro_id', 'dharma',
    'janela_dias', jan.dias, 'de', jan.de, 'ate', jan.ate,
    'meta_coletado_em', (select to_char(max(d.atualizado_em) at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS"-03:00"')
                           from public.meta_ads_diario d where d.dia between jan.de and jan.ate),
    'atribuicao_desde', (select to_char(min(r.recebido_em) at time zone 'America/Sao_Paulo', 'YYYY-MM-DD')
                           from public.meta_referrals r where r.ad_id is not null),
    'legenda', jsonb_build_object(
      'conversas_meta', 'conversas iniciadas no WhatsApp contadas pela Meta (meta_ads_diario, janela de 7 d da Meta)',
      'conversas', 'conversas que chegaram na Mari pelo WhatsApp, pelo dia em que nasceram (canal e telefones de teste fora desde 12/11, 0147)',
      'responderam', 'cliente mandou 2 ou mais mensagens',
      'cep_valido_area', 'CEP informado e dentro da área de atuação',
      'fora_area', 'fora da área de atuação (CEP ou elegibilidade)',
      'sem_cobertura', 'destino sem_cobertura (portal ou operador sem viabilidade, Saída Sem cobertura); fora_area e ja_cliente_nio também são o destino único desde 0147',
      'qualificadas', 'LEGADO: Mari passou para o time com dados completos (handoff dados_completos), sem olhar viabilidade nem cliente Nio',
      'qualificadas_reais', 'USE ESTA: etapa qualificada ou além (dados completos + viável + não é cliente Nio + crédito não negado), sem já cliente ou crédito negado depois (0147)',
      'por_destino', 'destino único de cada conversa, soma = conversas: em_andamento, instalada, reprovado_biometria, credito_negado, ja_cliente_nio, fora_area, sem_cobertura, recusou, sem_resposta',
      'por_etapa', 'etapa mais alta alcançada: nova, respondeu, cep, area_ok, viavel, viu_planos, qualificada, pedido, biometria, agendada, instalada. sem cidade em por_cidade = quem ainda não deu o CEP',
      'pedidos_abertos', 'venda com pedido no portal Nio ou status vendido em diante',
      'biometria_aprovada', 'venda com biometria validada = a venda que decide (custo_por.venda); até 12/11 procurava aprovada e dava sempre 0',
      'saidas', 'destino de saída → contagem, uma por conversa (pedido_humano e multiplos_decisores não são saída)',
      'por_anuncio', 'funil só das conversas com referral do anúncio (ad_id); antes de atribuicao_desde nenhuma conversa tinha anúncio, então anúncio com gasto e 0 conversas aqui pode ser só falta de atribuição',
      'custo_por', 'gasto da Meta na janela ÷ conversas_meta; os demais ÷ marcos das conversas com origem meta_ads (atribuídas ou não)',
      'privacidade', 'só contagens; sem nome, CPF, telefone, endereço, CEP ou bairro'),
    'totais', jsonb_build_object('gasto', mt.gasto, 'impressoes', mt.impressoes, 'cliques', mt.cliques,
                                 'conversas_meta', mt.conversas_meta,
                                 'conversas_atribuidas', (select count(*) from base where ad_id is not null),
                                 'conversas_teste_excluidas', (select count(*) from public.mari_conversas x
                                                                where x.canal = 'whatsapp' and x.funil_destino = 'teste_duplicada'
                                                                  and (x.created_at at time zone 'America/Sao_Paulo')::date >= jan.de)) || ft.funil,
    'custo_por', jsonb_build_object(
      'conversa', case when mt.conversas_meta > 0 then round(mt.gasto / mt.conversas_meta, 2) end,
      'cep_valido', case when (fm.funil ->> 'cep_valido_area')::int > 0 then round(mt.gasto / (fm.funil ->> 'cep_valido_area')::int, 2) end,
      'qualificada', case when (fm.funil ->> 'qualificadas')::int > 0 then round(mt.gasto / (fm.funil ->> 'qualificadas')::int, 2) end,
      'qualificada_real', case when (fm.funil ->> 'qualificadas_reais')::int > 0 then round(mt.gasto / (fm.funil ->> 'qualificadas_reais')::int, 2) end,
      'venda', case when (fm.funil ->> 'biometria_aprovada')::int > 0 then round(mt.gasto / (fm.funil ->> 'biometria_aprovada')::int, 2) end),
    'por_dia', coalesce((
      select jsonb_agg(jsonb_build_object('dia', k.dia, 'gasto', coalesce(md.gasto, 0), 'conversas_meta', coalesce(md.conversas_meta, 0))
                       || coalesce(fd.funil, (select z from zero)) order by k.dia)
        from (select dia from m where g_dia union select dia from f where g_dia) k
        left join m md on md.g_dia and md.dia = k.dia
        left join f fd on fd.g_dia and fd.dia = k.dia), '[]'::jsonb),
    'por_anuncio', coalesce((
      select jsonb_agg(jsonb_build_object('ad_id', k.ad_id, 'ad_nome', a.ad_nome, 'conjunto_id', a.adset_id, 'conjunto', a.adset_nome,
                                          'campanha', a.campanha_nome, 'status', a.status_efetivo,
                                          'gasto', coalesce(ma.gasto, 0), 'impressoes', coalesce(ma.impressoes, 0),
                                          'conversas_meta', coalesce(ma.conversas_meta, 0),
                                          'custo_cep_valido', case when (fa.funil ->> 'cep_valido_area')::int > 0
                                                                   then round(ma.gasto / (fa.funil ->> 'cep_valido_area')::int, 2) end,
                                          'custo_venda', case when (fa.funil ->> 'biometria_aprovada')::int > 0
                                                              then round(ma.gasto / (fa.funil ->> 'biometria_aprovada')::int, 2) end)
                       || coalesce(fa.funil, (select z from zero))
                       order by coalesce(ma.gasto, 0) desc, k.ad_id)
        from (select ad_id from m where g_ad and ad_id is not null union select ad_id from f where g_ad and ad_id is not null) k
        left join public.meta_ads_anuncios a on a.ad_id = k.ad_id
        left join m ma on ma.g_ad and ma.ad_id = k.ad_id
        left join f fa on fa.g_ad and fa.ad_id = k.ad_id), '[]'::jsonb),
    'por_conjunto', coalesce((
      select jsonb_agg(jsonb_build_object('conjunto_id', k.adset_id, 'conjunto', c.adset_nome, 'campanha', c.campanha_nome,
                                          'gasto', coalesce(mc.gasto, 0), 'conversas_meta', coalesce(mc.conversas_meta, 0),
                                          'custo_cep_valido', case when (fc.funil ->> 'cep_valido_area')::int > 0
                                                                   then round(mc.gasto / (fc.funil ->> 'cep_valido_area')::int, 2) end,
                                          'custo_venda', case when (fc.funil ->> 'biometria_aprovada')::int > 0
                                                              then round(mc.gasto / (fc.funil ->> 'biometria_aprovada')::int, 2) end)
                       || coalesce(fc.funil, (select z from zero))
                       order by coalesce(mc.gasto, 0) desc, k.adset_id)
        from (select adset_id from m where g_conj and adset_id is not null
              union select conjunto_id from f where g_conj and conjunto_id is not null) k
        left join lateral (select a.adset_nome, a.campanha_nome from public.meta_ads_anuncios a
                            where a.adset_id = k.adset_id order by a.atualizado_em desc limit 1) c on true
        left join m mc on mc.g_conj and mc.adset_id = k.adset_id
        left join f fc on fc.g_conj and fc.conjunto_id = k.adset_id), '[]'::jsonb),
    'por_cidade', coalesce((
      select jsonb_agg(jsonb_build_object('cidade', x.cidade) || x.funil order by (x.funil ->> 'conversas')::int desc, x.cidade)
        from f x where x.g_cid), '[]'::jsonb),
    'por_origem', coalesce((
      select jsonb_agg(jsonb_build_object('origem', x.origem) || x.funil order by (x.funil ->> 'conversas')::int desc, x.origem)
        from f x where x.g_ori), '[]'::jsonb)
  )
  from jan, mt, ft, fm
$$;
revoke execute on function public.agente_trafego_retrato(int) from public, anon, authenticated;
grant execute on function public.agente_trafego_retrato(int) to service_role;

-- ───────────────────────── 11. backfill ─────────────────────────
-- Todas as conversas: o gatilho antes calcula etapa e destino (1º cálculo usa o estado atual dos sinais); o gatilho depois
-- grava o evento e enfileira etiqueta saida-<destino> + resolve das saídas que ainda estão abertas no Chatwoot.
update public.mari_conversas set funil_evento = 'backfill' where funil_destino is null;
