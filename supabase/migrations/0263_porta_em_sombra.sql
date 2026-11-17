-- NIOGEN | supabase/migrations/0263_porta_em_sombra.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Passo 4c do caminho (porta única) — Ricardo, 17/11: "Sim" (4c + dois consertos).
-- EM SOMBRA: nada do que o sistema faz muda. Cria:
--   (1) config_evento — os eventos que mudam um lead (quem dispara e por qual função).
--   (2) config_transicao — situação × evento → para que situação(ões) vai, ou RECUSA com a frase que a tela vai mostrar.
--       Tokens em "para": '=' fica onde está · 'andamento' qualquer das situações 1–10 · '*' qualquer uma.
--       "de" aceita a situação, o grupo ('andamento' 1–10, 'saida_pode_voltar'…), '(novo)' ou '*'.
--       Ordem de leitura: evento exato antes da família (saida:* , momento:credito:*), situação antes do grupo, antes de '*';
--       o evento '*' (a regra das situações finais) só vale quando nenhuma regra do evento serve.
--   (3) porta_prever(situação, evento) — a resposta da tabela. É a mesma que a tela vai usar para desenhar só os botões aceitos.
--   (4) porta_sombra — o diário: cada evento real, a situação antes e depois, o que a tabela previa e se concordou.
--   (5) As 15 funções que mudam um lead viram "<nome>__nucleo" (o corpo de sempre, intocado) e ganham, com o nome antigo,
--       uma casca que lê a situação antes, chama o núcleo, lê a situação depois e anota. A anotação NUNCA derruba o evento
--       (erro nela é engolido) e só a chamada de fora anota (chamadas aninhadas não repetem a linha).
--       ⚠ Daqui em diante, mudar uma dessas funções = mudar o "__nucleo". O portão confere que a casca está no lugar (R11).
--   (6) v_porta_divergencias — onde a tabela e o sistema discordam: cada linha é um furo de regra ou um caminho sem desenho.
-- Fora desta parte (anotados no passo 5): robôs em lote (_saidas_fechar, cadência, leitura do OSAB) e recusas do sistema por
-- erro (a transação volta inteira, então não há o que anotar).
begin;

-- ── (0) grupo das situações ──
alter table public.config_situacao add column if not exists grupo text;
update public.config_situacao set grupo = case when numero between 1 and 10 then 'andamento' when numero in (12, 13) then 'saida' end;

-- ── (1) eventos ──
create table if not exists public.config_evento (
  codigo  text primary key,
  nome    text not null,
  funcao  text not null,
  quem    text not null,
  nota    text
);
alter table public.config_evento enable row level security;
drop policy if exists config_evento_ler on public.config_evento;
create policy config_evento_ler on public.config_evento for select to authenticated using (true);
grant select on public.config_evento to authenticated;

insert into public.config_evento (codigo, nome, funcao, quem, nota) values
  ('cliente_escreveu',     'Cliente escreveu',                    'mari_entrada',                  'cliente',   null),
  ('mari_passou:*',        'A Mari passou adiante (handoff)',     'mari_handoff',                  'Mari',      'um evento por motivo do handoff'),
  ('saida:*',              'Saída',                               'lead_sair',                     'time',      'um evento por motivo (config_lead)'),
  ('reabrir',              'Reabrir',                             'lead_reabrir',                  'time',      null),
  ('momento:*',            'Passo da venda (botões da ficha)',    'backoffice_momento',            'time',      'assumir, viabilidade, crédito, pedido, biometria, OS, agendar, parar, devolver à Mari'),
  ('silenciar:*',          'Saída/silenciar da conversa sem venda','backoffice_conversa_saida',    'time',      null),
  ('aguardar',             'Em espera com data',                  'backoffice_conversa_espera',    'time',      null),
  ('dispensar',            'Nada a responder',                    'backoffice_conversa_dispensar', 'time',      null),
  ('conversa:*',           'Mexer no Chatwoot pelo NIOGEN',       'backoffice_conversa',           'time',      'atribuir, status, etiquetas'),
  ('time_respondeu',       'Time respondeu ao cliente',           'backoffice_responder',          'time',      null),
  ('time_nota',            'Time deixou nota',                    'backoffice_responder',          'time',      null),
  ('nao_contatar',         'Não contatar',                        'conversa_nao_contatar',         'cliente ou time', null),
  ('virar_venda',          'Virar venda',                         'lead_virar_venda',              'time',      null),
  ('trocar_titular',       'Trocar o titular',                    'venda_trocar_titular',          'time',      null),
  ('mover_admin:*',        'Mover (admin)',                       'venda_mover_admin',             'admin',     null),
  ('antifraude:*',         'Decisão do antifraude',               'lead_antifraude_decidir',       'time',      null)
on conflict (codigo) do update set nome = excluded.nome, funcao = excluded.funcao, quem = excluded.quem, nota = excluded.nota;

-- ── (2) a tabela situação × evento ──
create table if not exists public.config_transicao (
  evento  text not null,
  de      text not null,
  para    text[],
  aceito  boolean not null,
  frase   text,
  nota    text,
  primary key (evento, de),
  check (aceito = (para is not null)),
  check (aceito or frase is not null)
);
alter table public.config_transicao enable row level security;
drop policy if exists config_transicao_ler on public.config_transicao;
create policy config_transicao_ler on public.config_transicao for select to authenticated using (true);
grant select on public.config_transicao to authenticated;

delete from public.config_transicao;
insert into public.config_transicao (evento, de, para, aceito, frase, nota) values
  -- situações finais: nenhum evento as muda, salvo os que dizem o contrário abaixo
  ('*', 'nao_contatar',     null, false, 'Não contatar: nada muda a situação. Só o próprio cliente pode voltar a escrever.', 'H1'),
  ('*', 'cliente_nio',      null, false, 'Cliente que já é Nio é de ninguém: somos revenda (canais oficiais: App Nio ou 0800).', 'Ricardo, 17/11'),
  ('*', 'saida_definitiva', null, false, 'Saída definitiva não reabre (crédito, biometria, fraude, Nio não instalou, teste).', 'X3'),
  ('*', 'instalada',        null, false, 'Venda instalada: o que vem agora é pós-venda.', null),
  -- cliente escreveu
  ('cliente_escreveu', '(novo)',            '{mari_atendendo,nao_contatar}', true, null, 'nasce com a Mari; "SAIR" na 1ª mensagem = Não contatar (A6)'),
  ('cliente_escreveu', '*',                 '{=,nao_contatar}',              true, null, 'escrever não muda a etapa; "SAIR" = Não contatar'),
  ('cliente_escreveu', 'saida_pode_voltar', '{andamento,=,nao_contatar}',    true, null, 'reabre na etapa onde parou (seção 7); fora da área + "ok" volta a fechar (B3) — passo 5: quais motivos reabrem'),
  ('cliente_escreveu', 'time_esperando',    '{time_agora,nao_contatar}',     true, null, 'C10: volta para o mesmo dono'),
  ('cliente_escreveu', 'em_espera',         '{=,time_agora,nao_contatar}',   true, null, 'C11: passo 5'),
  ('cliente_escreveu', 'nao_contatar',      '{=}', true, null, 'a Mari não responde; nada muda'),
  ('cliente_escreveu', 'cliente_nio',       '{=}', true, null, 'insistiu: silenciada, ninguém atende (0261)'),
  ('cliente_escreveu', 'saida_definitiva',  '{=}', true, null, 'resposta curta, sem venda'),
  ('cliente_escreveu', 'instalada',         '{=}', true, null, 'pós-instalação e indicação'),
  ('cliente_escreveu', 'instalacao_aguardando', '{=,instalacao_agendar,nao_contatar}', true, null, 'E3: pediu para remarcar → agendar (0256)'),
  -- a Mari passou adiante
  ('mari_passou:dados_completos',     'andamento', '{qualificado_credito,qualificado_biometria,qualificado_os}', true, null, 'C1'),
  ('mari_passou:pedido_humano',       'andamento', '{time_agora,=}', true, null, 'C2; com venda, a etapa fica'),
  ('mari_passou:objecao',             'andamento', '{time_agora,=}', true, null, 'C2'),
  ('mari_passou:urgencia_alta',       'andamento', '{time_agora,=}', true, null, 'C2'),
  ('mari_passou:multiplos_decisores', 'andamento', '{time_agora,=}', true, null, 'C3: passo 5'),
  ('mari_passou:interesse_caindo',    'andamento', '{=}',            true, null, 'C3: fica com a Mari'),
  ('mari_passou:recusa_compra',       'andamento', '{saida_pode_voltar}', true, null, 'B13'),
  ('mari_passou:fora_de_area',        'andamento', '{saida_pode_voltar}', true, null, 'B3'),
  ('mari_passou:sem_cobertura',       'andamento', '{saida_pode_voltar}', true, null, 'B2: volta em 90 dias'),
  ('mari_passou:ja_cliente_nio',      'andamento', '{cliente_nio}',       true, null, 'A5'),
  ('mari_passou:*',                   'saida',     null, false, 'Em Saída a Mari só volta a falar se o cliente escrever (reabre).', null),
  -- reabrir
  ('reabrir', 'saida_pode_voltar', '{andamento}', true, null, null),
  ('reabrir', 'andamento',         null, false, 'Não está em Saída: nada a reabrir.', null),
  -- conversa sem venda: Saída/silenciar
  ('silenciar:perdida',         'andamento', '{saida_pode_voltar}', true, null, 'nome antigo de Recusou'),
  ('silenciar:recusou',         'andamento', '{saida_pode_voltar}', true, null, null),
  ('silenciar:fora_area',       'andamento', '{saida_pode_voltar}', true, null, null),
  ('silenciar:sem_cobertura',   'andamento', '{saida_pode_voltar}', true, null, null),
  ('silenciar:sem_resposta',    'andamento', '{saida_pode_voltar}', true, null, null),
  ('silenciar:credito_negado',  'andamento', '{saida_definitiva}',  true, null, null),
  ('silenciar:teste_duplicada', 'andamento', '{saida_definitiva}',  true, null, null),
  ('silenciar:ja_cliente',      'andamento', '{cliente_nio}', true, null, 'nome antigo'),
  ('silenciar:ja_cliente_nio',  'andamento', '{cliente_nio}', true, null, null),
  ('silenciar:suporte_nio',     'andamento', '{cliente_nio}', true, null, '0261'),
  ('silenciar:suporte_nio',     'saida',     '{cliente_nio}', true, null, '0261'),
  ('silenciar:reativar',        'saida_pode_voltar', '{andamento}', true, null, null),
  -- espera, avisos, Chatwoot, fala do time
  ('aguardar',          'andamento', '{em_espera}', true, null, 'B8'),
  ('dispensar',         '*', '{=}', true, null, 'só tira o aviso do Live'),
  ('conversa:atribuir', 'andamento', '{=,time_agora}', true, null, 'C6: atribuir = Assumir'),
  ('conversa:*',        '*', '{=}', true, null, 'mexe só no Chatwoot; no passo 5 vira evento conhecido ou é desfeito (H2, H3)'),
  ('time_respondeu',    'mari_atendendo', '{time_agora}', true, null, 'C7: responder sem assumir = a vez passa ao time'),
  ('time_respondeu',    '*', '{=}', true, null, 'passo 5: com o time, esperando o cliente (situação 3)'),
  ('time_nota',         '*', '{=}', true, null, null),
  -- Não contatar
  ('nao_contatar', '*', '{nao_contatar,=}', true, null, 'com venda viva a venda segue, sem mensagens (H1)'),
  -- venda
  ('virar_venda',    'andamento', '{qualificado_credito,qualificado_biometria,qualificado_os}', true, null, 'D6'),
  ('trocar_titular', 'andamento', '{=,qualificado_credito,qualificado_biometria}', true, null, 'D16'),
  ('trocar_titular', 'instalacao_agendar',    null, false, 'Depois da OS, trocar o titular é uma venda nova (0256).', null),
  ('trocar_titular', 'instalacao_aguardando', null, false, 'Depois da OS, trocar o titular é uma venda nova (0256).', null),
  ('trocar_titular', 'instalacao_pendencia',  null, false, 'Depois da OS, trocar o titular é uma venda nova (0256).', null),
  ('mover_admin:*',  '*', '{*}', true, null, 'o admin pode tudo — fica anotado'),
  ('antifraude:*',   'andamento', '{andamento,cliente_nio,saida_definitiva,saida_pode_voltar}', true, null, 'dele → já é cliente Nio; outro morador → defesa; liberado/recusado'),
  -- passos da venda (botões da ficha)
  ('momento:assumir',              'mari_atendendo', '{time_agora}', true, null, 'C5'),
  ('momento:assumir',              'andamento', '{=,time_agora}', true, null, 'C5'),
  ('momento:assumir',              'saida', null, false, 'Em Saída: reabra antes de assumir.', 'X2'),
  ('momento:viabilidade:viavel',   'andamento', '{=}', true, null, 'D1'),
  ('momento:viabilidade:*',        'andamento', '{=,saida_pode_voltar}', true, null, 'D2: sem viabilidade → Saída'),
  ('momento:credito:aprovado',     'andamento', '{qualificado_credito,qualificado_biometria,qualificado_os}', true, null, 'D3: aprovado → fazer o pedido (segue em 5) → biometria'),
  ('momento:credito:so_cartao',    'andamento', '{qualificado_credito,qualificado_biometria,qualificado_os}', true, null, 'D4: idem, no cartão'),
  ('momento:credito:pendente',     'andamento', '{=,qualificado_credito}', true, null, 'D5'),
  ('momento:credito:negado',       'andamento', '{=,qualificado_credito,em_espera}', true, null, 'B10: pede outro CPF e espera o cliente'),
  ('momento:pedido',               'andamento', '{=,qualificado_credito,qualificado_biometria}', true, null, null),
  ('momento:biometria:validada',   'andamento', '{qualificado_os,instalacao_agendar,instalacao_aguardando}', true, null, 'D8'),
  ('momento:biometria:dispensada', 'andamento', '{qualificado_os,instalacao_agendar,instalacao_aguardando}', true, null, 'D11'),
  ('momento:biometria:negado',     'andamento', '{saida_definitiva,=}', true, null, 'D10'),
  ('momento:biometria:*',          'andamento', '{=}', true, null, 'risco: segue'),
  ('momento:os',                   'qualificado_credito',   null, false, 'OS só com a biometria aprovada (0256).', 'D11'),
  ('momento:os',                   'qualificado_biometria', null, false, 'OS só com a biometria aprovada (0256).', 'D11'),
  ('momento:os',                   'andamento', '{instalacao_agendar,instalacao_aguardando}', true, null, 'D12'),
  ('momento:os_agendar',           'qualificado_credito',   null, false, 'OS só com a biometria aprovada (0256).', 'D11'),
  ('momento:os_agendar',           'qualificado_biometria', null, false, 'OS só com a biometria aprovada (0256).', 'D11'),
  ('momento:os_agendar',           'andamento', '{instalacao_aguardando}', true, null, null),
  ('momento:agendar',              'andamento', '{instalacao_aguardando}', true, null, 'D13'),
  ('momento:reagendar',            'andamento', '{instalacao_aguardando}', true, null, 'D14'),
  ('momento:parar',                'andamento', '{nao_contatar,=}', true, null, 'H1: com venda viva a venda segue, sem mensagens'),
  ('momento:parar',                'saida',     '{nao_contatar}',   true, null, null),
  ('momento:devolver_mari',        'andamento', '{mari_atendendo,=}', true, null, 'C8: passa só a conversa');

-- Saída: um evento por motivo, gerado da própria lista de motivos (config_lead) e da classificação (lead_situacao)
insert into public.config_transicao (evento, de, para, aceito, frase, nota)
select 'saida:' || k.codigo, d.de,
       case when k.codigo = 'nao_contatar' and d.de = 'andamento' then array['nao_contatar', '=']
            else array[public.lead_situacao('x', 'saida', k.codigo, false, null)] end,
       true, null, case when d.de = 'saida_pode_voltar' then 'troca o motivo da Saída' when k.codigo = 'nao_contatar' then 'H1' end
  from public.config_lead k
 cross join (values ('andamento'), ('saida_pode_voltar')) d(de)
 where k.parceiro_id = 'dharma' and k.tipo = 'saida'
on conflict (evento, de) do nothing;

-- ── (3) a resposta da tabela ──
create or replace function public._situacao_grupo(p text) returns text language sql stable set search_path = public as $$
  select grupo from public.config_situacao where codigo = p
$$;

create or replace function public.porta_prever(p_de text, p_evento text)
returns table (aceito boolean, para text[], frase text, regra text) language plpgsql stable set search_path = public as $$
declare
  de    text := coalesce(p_de, '(novo)');
  partes text[] := string_to_array(coalesce(p_evento, ''), ':');
  evs   text[] := array[coalesce(p_evento, '')];
  des   text[];
  e text; d text; t public.config_transicao;
begin
  for k in reverse coalesce(array_length(partes, 1), 1) - 1 .. 1 loop
    evs := evs || (array_to_string(partes[1:k], ':') || ':*');
  end loop;
  des := array_remove(array[de, public._situacao_grupo(de), '*'], null);
  foreach e in array evs || array['*'] loop
    foreach d in array des loop
      select * into t from public.config_transicao x where x.evento = e and x.de = d;
      if found then
        return query select t.aceito, t.para, t.frase, e || ' @ ' || d;
        return;
      end if;
    end loop;
  end loop;
  return query select null::boolean, null::text[], 'sem regra na tabela para este evento nesta situação'::text, null::text;
end $$;
grant execute on function public.porta_prever(text, text) to authenticated;

create or replace function public._porta_bate(p_antes text, p_depois text, p_para text[]) returns boolean language sql stable set search_path = public as $$
  select exists (select 1 from unnest(p_para) t
                  where t = '*' or t = p_depois or (t = '=' and p_depois is not distinct from p_antes)
                     or (t in ('andamento', 'saida') and public._situacao_grupo(p_depois) = t))
$$;

-- ── (4) o diário da sombra ──
create table if not exists public.porta_sombra (
  id             bigserial primary key,
  em             timestamptz not null default now(),
  evento         text not null,
  origem         text not null,
  conversa_id    uuid,
  venda_id       uuid,
  antes          text,
  depois         text,
  aceito         boolean,          -- null = sem regra na tabela
  para           text[],
  frase          text,
  regra          text,
  concorda       boolean,          -- null = sem regra
  sistema_ok     boolean,
  sistema_resumo text,
  por            uuid
);
create index if not exists porta_sombra_em on public.porta_sombra (em);
create index if not exists porta_sombra_conversa on public.porta_sombra (conversa_id);
alter table public.porta_sombra enable row level security;
drop policy if exists porta_sombra_ler on public.porta_sombra;
create policy porta_sombra_ler on public.porta_sombra for select to authenticated using (true);
grant select on public.porta_sombra to authenticated;

create or replace function public._porta_situacao(p_conversa uuid, p_venda uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare s text; achou boolean;
begin
  if p_conversa is null and p_venda is null then return '(novo)'; end if;
  select ls.situacao, true into s, achou from public.v_lead_situacao ls
   where (p_conversa is not null and ls.conversa_id = p_conversa) or (p_venda is not null and ls.venda_id = p_venda)
   limit 1;
  return case when achou then coalesce(s, '(sem situação)') else '(novo)' end;
exception when others then return '(erro)';
end $$;

create or replace function public._porta_anotar(p_evento text, p_origem text, p_conversa uuid, p_venda uuid, p_antes text, r jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare ls record; p record; d text;
begin
  select l.situacao, l.conversa_id, l.venda_id into ls from public.v_lead_situacao l
   where (p_conversa is not null and l.conversa_id = p_conversa) or (p_venda is not null and l.venda_id = p_venda)
   limit 1;
  d := coalesce(ls.situacao, case when p_conversa is null and p_venda is null then '(novo)' else '(sem situação)' end);
  select * into p from public.porta_prever(p_antes, p_evento);
  insert into public.porta_sombra (evento, origem, conversa_id, venda_id, antes, depois, aceito, para, frase, regra, concorda,
                                   sistema_ok, sistema_resumo, por)
  values (p_evento, p_origem, coalesce(ls.conversa_id, p_conversa), coalesce(ls.venda_id, p_venda), p_antes, d,
          p.aceito, p.para, p.frase, p.regra,
          case when p.aceito is null then null
               when p.aceito then public._porta_bate(p_antes, d, p.para)
               else d is not distinct from p_antes end,
          coalesce((r ->> 'ok')::boolean, true), left(coalesce(r ->> 'resumo', r ->> 'erro', r ->> 'status'), 300), auth.uid());
exception when others then
  null;   -- a sombra nunca derruba o evento
end $$;

-- ── (5) as cascas ──

-- mari_entrada  →  evento 'cliente_escreveu'
alter function public.mari_entrada(text, text, text, text, text, text, jsonb) rename to mari_entrada__nucleo;
revoke execute on function public.mari_entrada__nucleo(text, text, text, text, text, text, jsonb) from public, anon, authenticated;
create function public.mari_entrada(p_telefone text, p_nome text, p_texto text, p_canal text DEFAULT 'teste'::text, p_origem text DEFAULT NULL::text, p_chatwoot_conversation_id text DEFAULT NULL::text, p_midia jsonb DEFAULT NULL::jsonb)
returns jsonb language plpgsql set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em mari_entrada__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.mari_entrada__nucleo(p_telefone, p_nome, p_texto, p_canal, p_origem, p_chatwoot_conversation_id, p_midia); end if;
  perform set_config('porta.dentro', 'mari_entrada', true);
  v_c := (select x.id from public.mari_conversas x where x.telefone = regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g') and x.canal = p_canal order by x.updated_at desc limit 1);
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.mari_entrada__nucleo(p_telefone, p_nome, p_texto, p_canal, p_origem, p_chatwoot_conversation_id, p_midia);
  perform set_config('porta.dentro', '', true);
  if v_c is distinct from nullif(r ->> 'conversa_id', '')::uuid then v_a := '(novo)'; end if;   -- conversa nova = lead novo
  perform public._porta_anotar('cliente_escreveu', 'mari_entrada', coalesce(nullif(r ->> 'conversa_id', '')::uuid, v_c), null::uuid, v_a, r);
  return r;
end $f$;
revoke execute on function public.mari_entrada(text, text, text, text, text, text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.mari_entrada(text, text, text, text, text, text, jsonb) to service_role;

-- mari_handoff  →  evento 'mari_passou:' || coalesce(p_motivo, '')
alter function public.mari_handoff(uuid, text, jsonb) rename to mari_handoff__nucleo;
revoke execute on function public.mari_handoff__nucleo(uuid, text, jsonb) from public, anon, authenticated;
create function public.mari_handoff(p_conversa uuid, p_motivo text, p_lead jsonb DEFAULT '{}'::jsonb)
returns jsonb language plpgsql set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em mari_handoff__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.mari_handoff__nucleo(p_conversa, p_motivo, p_lead); end if;
  perform set_config('porta.dentro', 'mari_handoff', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.mari_handoff__nucleo(p_conversa, p_motivo, p_lead);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('mari_passou:' || coalesce(p_motivo, ''), 'mari_handoff', v_c, null::uuid, v_a, r);
  return r;
end $f$;
revoke execute on function public.mari_handoff(uuid, text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.mari_handoff(uuid, text, jsonb) to service_role;

-- lead_sair  →  evento 'saida:' || coalesce(p_motivo, '')
alter function public.lead_sair(uuid, uuid, text, text, date, text, boolean) rename to lead_sair__nucleo;
revoke execute on function public.lead_sair__nucleo(uuid, uuid, text, text, date, text, boolean) from public, anon, authenticated;
create function public.lead_sair(p_conversa uuid, p_venda uuid, p_motivo text, p_sub text DEFAULT NULL::text, p_volta date DEFAULT NULL::date, p_obs text DEFAULT NULL::text, p_cancelou_portal boolean DEFAULT NULL::boolean)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em lead_sair__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.lead_sair__nucleo(p_conversa, p_venda, p_motivo, p_sub, p_volta, p_obs, p_cancelou_portal); end if;
  perform set_config('porta.dentro', 'lead_sair', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, p_venda);
  r := public.lead_sair__nucleo(p_conversa, p_venda, p_motivo, p_sub, p_volta, p_obs, p_cancelou_portal);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('saida:' || coalesce(p_motivo, ''), 'lead_sair', v_c, p_venda, v_a, r);
  return r;
end $f$;
revoke execute on function public.lead_sair(uuid, uuid, text, text, date, text, boolean) from public, anon, authenticated, service_role;
grant execute on function public.lead_sair(uuid, uuid, text, text, date, text, boolean) to authenticated, service_role;

-- lead_reabrir  →  evento 'reabrir'
alter function public.lead_reabrir(uuid, uuid) rename to lead_reabrir__nucleo;
revoke execute on function public.lead_reabrir__nucleo(uuid, uuid) from public, anon, authenticated;
create function public.lead_reabrir(p_conversa uuid, p_venda uuid)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em lead_reabrir__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.lead_reabrir__nucleo(p_conversa, p_venda); end if;
  perform set_config('porta.dentro', 'lead_reabrir', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, p_venda);
  r := public.lead_reabrir__nucleo(p_conversa, p_venda);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('reabrir', 'lead_reabrir', v_c, p_venda, v_a, r);
  return r;
end $f$;
revoke execute on function public.lead_reabrir(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.lead_reabrir(uuid, uuid) to authenticated, service_role;

-- backoffice_momento  →  evento 'momento:' || coalesce(p_momento, '') || coalesce(':' || nullif(p_dados ->> 'resultado', ''), '')
alter function public.backoffice_momento(uuid, text, jsonb) rename to backoffice_momento__nucleo;
revoke execute on function public.backoffice_momento__nucleo(uuid, text, jsonb) from public, anon, authenticated;
create function public.backoffice_momento(p_venda uuid, p_momento text, p_dados jsonb DEFAULT '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em backoffice_momento__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.backoffice_momento__nucleo(p_venda, p_momento, p_dados); end if;
  perform set_config('porta.dentro', 'backoffice_momento', true);
  v_c := null::uuid;
  v_a := public._porta_situacao(v_c, p_venda);
  r := public.backoffice_momento__nucleo(p_venda, p_momento, p_dados);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('momento:' || coalesce(p_momento, '') || coalesce(':' || nullif(p_dados ->> 'resultado', ''), ''), 'backoffice_momento', v_c, p_venda, v_a, r);
  return r;
end $f$;
revoke execute on function public.backoffice_momento(uuid, text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.backoffice_momento(uuid, text, jsonb) to authenticated, service_role;

-- backoffice_conversa_saida  →  evento 'silenciar:' || coalesce(p_motivo, '')
alter function public.backoffice_conversa_saida(uuid, text) rename to backoffice_conversa_saida__nucleo;
revoke execute on function public.backoffice_conversa_saida__nucleo(uuid, text) from public, anon, authenticated;
create function public.backoffice_conversa_saida(p_conversa uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em backoffice_conversa_saida__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.backoffice_conversa_saida__nucleo(p_conversa, p_motivo); end if;
  perform set_config('porta.dentro', 'backoffice_conversa_saida', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.backoffice_conversa_saida__nucleo(p_conversa, p_motivo);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('silenciar:' || coalesce(p_motivo, ''), 'backoffice_conversa_saida', v_c, null::uuid, v_a, r);
  return r;
end $f$;
revoke execute on function public.backoffice_conversa_saida(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.backoffice_conversa_saida(uuid, text) to authenticated, service_role;

-- backoffice_conversa_espera  →  evento 'aguardar'
alter function public.backoffice_conversa_espera(uuid, date, text) rename to backoffice_conversa_espera__nucleo;
revoke execute on function public.backoffice_conversa_espera__nucleo(uuid, date, text) from public, anon, authenticated;
create function public.backoffice_conversa_espera(p_conversa uuid, p_ate date, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em backoffice_conversa_espera__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.backoffice_conversa_espera__nucleo(p_conversa, p_ate, p_motivo); end if;
  perform set_config('porta.dentro', 'backoffice_conversa_espera', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.backoffice_conversa_espera__nucleo(p_conversa, p_ate, p_motivo);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('aguardar', 'backoffice_conversa_espera', v_c, null::uuid, v_a, r);
  return r;
end $f$;
revoke execute on function public.backoffice_conversa_espera(uuid, date, text) from public, anon, authenticated, service_role;
grant execute on function public.backoffice_conversa_espera(uuid, date, text) to authenticated, service_role;

-- backoffice_conversa_dispensar  →  evento 'dispensar'
alter function public.backoffice_conversa_dispensar(uuid) rename to backoffice_conversa_dispensar__nucleo;
revoke execute on function public.backoffice_conversa_dispensar__nucleo(uuid) from public, anon, authenticated;
create function public.backoffice_conversa_dispensar(p_conversa uuid)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em backoffice_conversa_dispensar__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.backoffice_conversa_dispensar__nucleo(p_conversa); end if;
  perform set_config('porta.dentro', 'backoffice_conversa_dispensar', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.backoffice_conversa_dispensar__nucleo(p_conversa);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('dispensar', 'backoffice_conversa_dispensar', v_c, null::uuid, v_a, r);
  return r;
end $f$;
revoke execute on function public.backoffice_conversa_dispensar(uuid) from public, anon, authenticated, service_role;
grant execute on function public.backoffice_conversa_dispensar(uuid) to authenticated, service_role;

-- backoffice_conversa  →  evento 'conversa:' || coalesce(p_acao, '')
alter function public.backoffice_conversa(uuid, text, text) rename to backoffice_conversa__nucleo;
revoke execute on function public.backoffice_conversa__nucleo(uuid, text, text) from public, anon, authenticated;
create function public.backoffice_conversa(p_conversa uuid, p_acao text, p_valor text)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em backoffice_conversa__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.backoffice_conversa__nucleo(p_conversa, p_acao, p_valor); end if;
  perform set_config('porta.dentro', 'backoffice_conversa', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.backoffice_conversa__nucleo(p_conversa, p_acao, p_valor);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('conversa:' || coalesce(p_acao, ''), 'backoffice_conversa', v_c, null::uuid, v_a, r);
  return r;
end $f$;
revoke execute on function public.backoffice_conversa(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.backoffice_conversa(uuid, text, text) to anon, authenticated, service_role;

-- backoffice_responder  →  evento case when coalesce(p_nota, false) then 'time_nota' else 'time_respondeu' end
alter function public.backoffice_responder(uuid, text, boolean, text) rename to backoffice_responder__nucleo;
revoke execute on function public.backoffice_responder__nucleo(uuid, text, boolean, text) from public, anon, authenticated;
create function public.backoffice_responder(p_conversa uuid, p_texto text, p_nota boolean DEFAULT false, p_template text DEFAULT NULL::text)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em backoffice_responder__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.backoffice_responder__nucleo(p_conversa, p_texto, p_nota, p_template); end if;
  perform set_config('porta.dentro', 'backoffice_responder', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.backoffice_responder__nucleo(p_conversa, p_texto, p_nota, p_template);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar(case when coalesce(p_nota, false) then 'time_nota' else 'time_respondeu' end, 'backoffice_responder', v_c, null::uuid, v_a, r);
  return r;
end $f$;
revoke execute on function public.backoffice_responder(uuid, text, boolean, text) from public, anon, authenticated, service_role;
grant execute on function public.backoffice_responder(uuid, text, boolean, text) to anon, authenticated, service_role;

-- conversa_nao_contatar  →  evento 'nao_contatar'
alter function public.conversa_nao_contatar(uuid, text) rename to conversa_nao_contatar__nucleo;
revoke execute on function public.conversa_nao_contatar__nucleo(uuid, text) from public, anon, authenticated;
create function public.conversa_nao_contatar(p_conversa uuid, p_origem text)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em conversa_nao_contatar__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.conversa_nao_contatar__nucleo(p_conversa, p_origem); end if;
  perform set_config('porta.dentro', 'conversa_nao_contatar', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.conversa_nao_contatar__nucleo(p_conversa, p_origem);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('nao_contatar', 'conversa_nao_contatar', v_c, null::uuid, v_a, r);
  return r;
end $f$;
revoke execute on function public.conversa_nao_contatar(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.conversa_nao_contatar(uuid, text) to authenticated, service_role;

-- lead_virar_venda  →  evento 'virar_venda'
alter function public.lead_virar_venda(uuid) rename to lead_virar_venda__nucleo;
revoke execute on function public.lead_virar_venda__nucleo(uuid) from public, anon, authenticated;
create function public.lead_virar_venda(p_conversa uuid)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em lead_virar_venda__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.lead_virar_venda__nucleo(p_conversa); end if;
  perform set_config('porta.dentro', 'lead_virar_venda', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.lead_virar_venda__nucleo(p_conversa);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('virar_venda', 'lead_virar_venda', v_c, null::uuid, v_a, r);
  return r;
end $f$;
revoke execute on function public.lead_virar_venda(uuid) from public, anon, authenticated, service_role;
grant execute on function public.lead_virar_venda(uuid) to authenticated, service_role;

-- venda_trocar_titular  →  evento 'trocar_titular'
alter function public.venda_trocar_titular(uuid, text, text, text, text, text) rename to venda_trocar_titular__nucleo;
revoke execute on function public.venda_trocar_titular__nucleo(uuid, text, text, text, text, text) from public, anon, authenticated;
create function public.venda_trocar_titular(p_venda uuid, p_nome text, p_cpf text, p_relacao text, p_motivo text DEFAULT NULL::text, p_credito text DEFAULT NULL::text)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em venda_trocar_titular__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.venda_trocar_titular__nucleo(p_venda, p_nome, p_cpf, p_relacao, p_motivo, p_credito); end if;
  perform set_config('porta.dentro', 'venda_trocar_titular', true);
  v_c := null::uuid;
  v_a := public._porta_situacao(v_c, p_venda);
  r := public.venda_trocar_titular__nucleo(p_venda, p_nome, p_cpf, p_relacao, p_motivo, p_credito);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('trocar_titular', 'venda_trocar_titular', v_c, p_venda, v_a, r);
  return r;
end $f$;
revoke execute on function public.venda_trocar_titular(uuid, text, text, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.venda_trocar_titular(uuid, text, text, text, text, text) to authenticated, service_role;

-- venda_mover_admin  →  evento 'mover_admin:' || coalesce(p_destino, '')
alter function public.venda_mover_admin(uuid, text, text) rename to venda_mover_admin__nucleo;
revoke execute on function public.venda_mover_admin__nucleo(uuid, text, text) from public, anon, authenticated;
create function public.venda_mover_admin(p_venda uuid, p_destino text, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em venda_mover_admin__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.venda_mover_admin__nucleo(p_venda, p_destino, p_motivo); end if;
  perform set_config('porta.dentro', 'venda_mover_admin', true);
  v_c := null::uuid;
  v_a := public._porta_situacao(v_c, p_venda);
  r := public.venda_mover_admin__nucleo(p_venda, p_destino, p_motivo);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('mover_admin:' || coalesce(p_destino, ''), 'venda_mover_admin', v_c, p_venda, v_a, r);
  return r;
end $f$;
revoke execute on function public.venda_mover_admin(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.venda_mover_admin(uuid, text, text) to authenticated, service_role;

-- lead_antifraude_decidir  →  evento 'antifraude:' || coalesce(p_decisao, '')
alter function public.lead_antifraude_decidir(uuid, text, text) rename to lead_antifraude_decidir__nucleo;
revoke execute on function public.lead_antifraude_decidir__nucleo(uuid, text, text) from public, anon, authenticated;
create function public.lead_antifraude_decidir(p_conversa uuid, p_decisao text, p_obs text DEFAULT NULL::text)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em lead_antifraude_decidir__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.lead_antifraude_decidir__nucleo(p_conversa, p_decisao, p_obs); end if;
  perform set_config('porta.dentro', 'lead_antifraude_decidir', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.lead_antifraude_decidir__nucleo(p_conversa, p_decisao, p_obs);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('antifraude:' || coalesce(p_decisao, ''), 'lead_antifraude_decidir', v_c, null::uuid, v_a, r);
  return r;
end $f$;
revoke execute on function public.lead_antifraude_decidir(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.lead_antifraude_decidir(uuid, text, text) to authenticated, service_role;


-- ── (6) a conferência ──
create or replace view public.v_porta_divergencias with (security_invoker = true) as
select s.id, s.em, s.evento, s.origem, s.conversa_id, s.venda_id, coalesce(c.nome_contato, '') as nome,
       s.antes, s.depois, s.aceito, s.para, s.frase, s.regra, s.sistema_ok, s.sistema_resumo,
       case when s.aceito is null then 'sem regra: caminho que ninguém desenhou'
            when s.aceito then 'a tabela previa ' || array_to_string(s.para, ' ou ') || ', o sistema levou a ' || coalesce(s.depois, '?')
            else 'a tabela recusaria ("' || s.frase || '"), o sistema levou a ' || coalesce(s.depois, '?') end as divergencia
  from public.porta_sombra s
  left join public.mari_conversas c on c.id = s.conversa_id
 where s.concorda is distinct from true
   and coalesce(c.telefone, '') not like '5500000000%' and coalesce(c.canal, 'whatsapp') <> 'teste';
grant select on public.v_porta_divergencias to authenticated;

create or replace view public.v_porta_resumo with (security_invoker = true) as
select s.evento, s.antes, s.depois, s.concorda, count(*) as vezes, max(s.em) as ultima
  from public.porta_sombra s
  left join public.mari_conversas c on c.id = s.conversa_id
 where coalesce(c.telefone, '') not like '5500000000%' and coalesce(c.canal, 'whatsapp') <> 'teste'
 group by 1, 2, 3, 4;
grant select on public.v_porta_resumo to authenticated;

commit;
