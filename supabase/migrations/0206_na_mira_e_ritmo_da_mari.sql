-- NIOGEN | supabase/migrations/0206_na_mira_e_ritmo_da_mari.sql | 15/11/2026 — Claude Code / Opus 5.5
-- Ricardo (15/11): "um humano pode intervir nas negociações para ajudar a Mari a fechar a venda, nem que seja só para observar…
-- os dois atentos às oportunidades" · "um termômetro dos atendimentos da Mari… o ritmo/estresse dela… que de fato o cliente esteja
-- interagindo". (O "Soprar para a Mari" fica para depois, separado — muda a Mari e passa pelo portão.)
--   1. mari_conversas.acompanhada_por / acompanhada_em / acompanhada_visto_em — quem do time está de olho (a Mari segue atendendo).
--   2. live_na_mira() — conversas QUENTES: o cliente escreveu nos últimos 30 min e o lead está em Viabilidade, Pré-qualificado ou
--      Qualificado (escada, v_leads), em andamento; mais as que alguém do time acompanha (até 3 dias). Última fala do cliente
--      (140 caracteres), trocas na última hora, vez, plano, quem acompanha e se o cliente escreveu depois da última olhada.
--   3. conversa_acompanhar(conversa, ligar) e conversa_acompanhar_visto(conversa) — admin/backoffice; só marcam (não assumem,
--      não mexem na cadência nem no Chatwoot).
--   4. mari_ritmo() — termômetro: conversando agora (cliente falou ≤ 15 min), esperando resposta (última fala é do cliente, ≤ 3 h)
--      e a maior espera, tempo de resposta típico e lento (60 min), conversas quentes (≥ 3 falas do cliente em 60 min), falas por
--      hora nas últimas 24 h e a média da mesma hora nos 7 dias anteriores, e o nível (Calmo · Ritmo bom · Pico · Sobrecarga)
--      pelos limites de config_regras.mari_ritmo.
-- Desempenho: tudo sai de mari_turnos (≈350 linhas/dia) pelo índice (conversa_id, created_at) + created_at recente.
-- Regra 20: (1) a vez e o prazo continuam os da escada; (2) "acompanhar" não cria estado de lead (é só olhar); (3) as marcas
-- mudam por função, com autor; (5) conferencia_itens: não precisa — nenhum número novo que feche conta.

alter table public.mari_conversas
  add column if not exists acompanhada_por      uuid,
  add column if not exists acompanhada_em       timestamptz,
  add column if not exists acompanhada_visto_em timestamptz;

create index if not exists mari_turnos_criado_idx on public.mari_turnos (created_at);

insert into public.config_regras (chave, valor, descricao, parceiro_id)
values ('mari_ritmo', '{"pico_conversas": 6, "sobrecarga_conversas": 12, "bom_conversas": 2, "espera_alerta_min": 3, "quente_falas": 3, "na_mira_min": 30}'::jsonb,
        'Termômetro da Mari (0206): conversando agora ≥ bom_conversas = Ritmo bom; ≥ pico_conversas = Pico; ≥ sobrecarga_conversas ou alguém esperando há mais de 2× espera_alerta_min = Sobrecarga. quente_falas = falas do cliente em 60 min para "quente". na_mira_min = janela do Na mira.',
        'dharma')
on conflict (chave) do nothing;

create or replace function public.live_na_mira()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_min int := coalesce((select (valor ->> 'na_mira_min')::int from public.config_regras where chave = 'mari_ritmo'), 30);
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return '[]'::jsonb; end if;
  with cand as (
    select c.* from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
       and (c.ultima_msg_lead_at > now() - make_interval(mins => v_min)
            or (c.acompanhada_por is not null and c.acompanhada_em > now() - interval '3 days'))
  )
  select coalesce(jsonb_agg(x order by x.acompanho desc, x.ultima_em desc), '[]'::jsonb) into r
    from (
      select c.id as conversa_id, coalesce(l.nome, c.dados ->> 'nome', c.nome_contato, 'Contato') as nome, c.cidade,
             l.etapa, l.etapa_nome, l.status_nome, l.vez, l.plano, l.valor_mensal, l.dono, l.destino,
             c.ultima_msg_lead_at as ultima_em,
             (select left(t.texto, 140) from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' order by t.created_at desc limit 1) as ultima_fala,
             (select count(*) from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > now() - interval '60 minutes') as falas_1h,
             c.acompanhada_por is not null as acompanhada,
             coalesce(c.acompanhada_por = auth.uid(), false) as acompanho,
             (select u.nome from public.usuarios u where u.id = c.acompanhada_por) as acompanhada_nome,
             (c.acompanhada_por is not null and c.ultima_msg_lead_at > coalesce(c.acompanhada_visto_em, c.acompanhada_em)) as novo
        from cand c
        left join public.v_leads l on l.conversa_id = c.id
       where c.acompanhada_por is not null
          or (coalesce(l.destino, 'em_andamento') = 'em_andamento' and l.etapa in ('viabilidade', 'pre_qualificado', 'qualificado'))
    ) x;
  return r;
end $$;
revoke all on function public.live_na_mira() from public, anon;
grant execute on function public.live_na_mira() to authenticated;

create or replace function public.conversa_acompanhar(p_conversa uuid, p_ligar boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  update public.mari_conversas
     set acompanhada_por = case when p_ligar then auth.uid() end,
         acompanhada_em = case when p_ligar then now() end,
         acompanhada_visto_em = case when p_ligar then now() end
   where id = p_conversa;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Conversa não encontrada.'; end if;
  return jsonb_build_object('ok', true, 'resumo', case when p_ligar then '👀 Acompanhando — a Mari segue; você vê aqui quando o cliente escrever' else 'Deixou de acompanhar' end);
end $$;
revoke all on function public.conversa_acompanhar(uuid, boolean) from public, anon;
grant execute on function public.conversa_acompanhar(uuid, boolean) to authenticated;

create or replace function public.conversa_acompanhar_visto(p_conversa uuid)
returns void language sql security definer set search_path = public as $$
  update public.mari_conversas set acompanhada_visto_em = now()
   where id = p_conversa and acompanhada_por = auth.uid() and coalesce(public.meu_perfil(), '') in ('admin', 'backoffice');
$$;
revoke all on function public.conversa_acompanhar_visto(uuid) from public, anon;
grant execute on function public.conversa_acompanhar_visto(uuid) to authenticated;

create or replace function public.mari_ritmo()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  cfg jsonb := coalesce((select valor from public.config_regras where chave = 'mari_ritmo'), '{}'::jsonb);
  v_agora int; v_esp int; v_esp_max numeric; v_p50 numeric; v_p90 numeric; v_quentes int; v_horas jsonb; v_nivel text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return null; end if;
  -- conversando agora: o cliente falou nos últimos 15 min
  select count(distinct conversa_id) into v_agora from public.mari_turnos
   where papel = 'lead' and created_at > now() - interval '15 minutes';
  -- esperando resposta: a última fala (cliente/Mari/time) é do cliente, nas últimas 3 h
  select count(*), max(extract(epoch from now() - x.created_at) / 60) into v_esp, v_esp_max
    from public.mari_conversas c
    join lateral (select t.papel, t.created_at from public.mari_turnos t
                   where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1) x on true
   where c.ultima_msg_lead_at > now() - interval '3 hours' and x.papel = 'lead' and coalesce(c.telefone, '') not like '5500000000%';
  -- tempo de resposta: cada fala do cliente na última hora até a próxima resposta (Mari ou time)
  select percentile_cont(0.5) within group (order by seg), percentile_cont(0.9) within group (order by seg) into v_p50, v_p90
    from (select extract(epoch from (select min(m.created_at) from public.mari_turnos m
                                      where m.conversa_id = l.conversa_id and m.papel in ('mari', 'humano') and m.created_at > l.created_at) - l.created_at) as seg
            from public.mari_turnos l where l.papel = 'lead' and l.created_at > now() - interval '60 minutes') s
   where seg is not null;
  -- quentes: ≥ quente_falas falas do cliente em 60 min
  select count(*) into v_quentes from (
    select conversa_id from public.mari_turnos where papel = 'lead' and created_at > now() - interval '60 minutes'
     group by conversa_id having count(*) >= coalesce((cfg ->> 'quente_falas')::int, 3)) q;
  -- falas por hora (24 h) e a média da mesma hora nos 7 dias anteriores
  with h as (select generate_series(date_trunc('hour', now()) - interval '23 hours', date_trunc('hour', now()), interval '1 hour') as hora),
  t as (select date_trunc('hour', created_at) as hora, papel, count(*) n from public.mari_turnos
         where created_at > now() - interval '8 days' and papel in ('lead', 'mari') group by 1, 2)
  select jsonb_agg(jsonb_build_object(
           'hora', to_char(h.hora at time zone 'America/Sao_Paulo', 'HH24'),
           'cliente', coalesce((select n from t where t.hora = h.hora and t.papel = 'lead'), 0),
           'mari', coalesce((select n from t where t.hora = h.hora and t.papel = 'mari'), 0),
           'media7', round(coalesce((select sum(n) from t where t.papel = 'lead' and t.hora in
                       (select h.hora - (d || ' days')::interval from generate_series(1, 7) d)), 0) / 7.0, 1)) order by h.hora)
    into v_horas from h;
  v_nivel := case
    when v_agora >= coalesce((cfg ->> 'sobrecarga_conversas')::int, 12)
      or coalesce(v_esp_max, 0) >= 2 * coalesce((cfg ->> 'espera_alerta_min')::int, 3) then 'sobrecarga'
    when v_agora >= coalesce((cfg ->> 'pico_conversas')::int, 6) then 'pico'
    when v_agora >= coalesce((cfg ->> 'bom_conversas')::int, 2) then 'bom'
    else 'calmo' end;
  return jsonb_build_object('nivel', v_nivel, 'agora', v_agora, 'esperando', coalesce(v_esp, 0), 'espera_max_min', round(coalesce(v_esp_max, 0), 1),
    'resposta_p50_s', round(coalesce(v_p50, 0)), 'resposta_p90_s', round(coalesce(v_p90, 0)), 'quentes', v_quentes, 'horas', coalesce(v_horas, '[]'::jsonb),
    'limites', cfg, 'em', now());
end $$;
revoke all on function public.mari_ritmo() from public, anon;
grant execute on function public.mari_ritmo() to authenticated;
