-- NIOGEN | supabase/migrations/0391_live2_reforco.sql | 24/11/2026 — Claude Code (Fable 5.2)
-- Live 2.0, passo 2 — a faixa REFORÇO (Ricardo, 24/11: "um hábito que tenho tido é intervir na conversa da Mari quando enxergo uma
-- oportunidade de venda… aquele gerente que fica de olho no atendimento do vendedor" · "vamos já incluir o plano Reforço").
-- Hoje ele garimpa isso na tela Conversas e nada fica medido. Aqui o banco aponta as conversas da Mari em que vale um gerente
-- entrar AGORA, por cinco sinais, e registra o que foi feito com cada uma:
--   escorregou  → "a Mari escorregou": o cliente repetiu a pergunta · a Mari repetiu a fala · o cliente disse "não entendi / já
--                 falei / não foi isso" · o cliente falou duas vezes seguidas e a Mari não respondeu há 3 min ou mais
--   objecao     → a Mari registrou objeção (preço, pensar, concorrente, consultar alguém) e o cliente falou nas últimas 2 h
--   quente      → 3 ou mais falas do cliente na última hora, já tendo visto os planos
--   pronto      → quase pronto: 6 ou mais dos 8 dados da venda já coletados, ainda sem venda (aproxima a regra O4 das 🔥)
--   sumiu       → viu os planos, a última fala é da Mari e o cliente está calado há 20 min–3 h
-- Dois modos de entrar (Ricardo: "Sem assinatura" → "Sim, dois modos"): SOPRAR (mari_soprar, que já existe: sai como fala da Mari e
-- ela segue) e ASSUMIR (o caminho de hoje). "Agora não" tira a linha por 24 h, com motivo. Nenhuma mensagem sai sozinha.
-- Só aparece conversa com a Mari atendendo, sem venda, em andamento, com a janela de 24 h aberta e sem "Não contatar".
-- Regra 20: (1)(2) não cria estado de lead; (3) Soprar e Assumir passam pela porta que já existe; (4) nenhum fato novo; (5) sem
-- conferência nova: é registro de uso (reforco_log) com o desfecho lido em reforco_resultado(). Regra de ouro 6: só por clique de
-- pessoa. Regra 10: nenhum evento novo. Regra 15: tabela com parceiro_id; limiares em config_regras.reforco_sinais.
-- "A Mari escorregou" são regras baratas e vão errar para os dois lados; o motivo "não era" do Agora não mede o erro.
-- Cenário X122.
begin;

insert into public.config_regras (chave, valor)
values ('reforco_sinais', jsonb_build_object(
  'objecoes', jsonb_build_array('preco', 'pensar', 'concorrente', 'consultar_alguem'), 'objecao_horas', 2,
  'sumiu_min', 20, 'sumiu_max_min', 180, 'quente_falas', 3, 'pronto_min', 6,
  'escorregou_horas', 2, 'mari_calada_min', 3, 'descanso_horas', 2, 'agora_nao_horas', 24,
  'etapas', jsonb_build_array('viu_planos', 'viavel', 'qualificada', 'biometria'),
  'motivos_agora_nao', jsonb_build_array(jsonb_build_object('codigo', 'ja_falei', 'nome', 'Já falei'),
    jsonb_build_object('codigo', 'nao_vale', 'nome', 'Não vale'), jsonb_build_object('codigo', 'nao_era', 'nome', 'Não era'),
    jsonb_build_object('codigo', 'depois', 'nome', 'Depois'))))
on conflict (chave) do nothing;

create table if not exists public.reforco_log (
  id          bigint generated always as identity primary key,
  parceiro_id text not null default 'dharma',
  conversa_id uuid not null,
  sinal       text not null,
  modo        text not null check (modo in ('so_mostrado', 'soprar', 'assumir', 'agora_nao')),
  motivo      text,
  etapa       text,
  por         uuid,
  em          timestamptz not null default now(),
  dia         date not null default ((now() at time zone 'America/Sao_Paulo')::date)
);
create unique index if not exists reforco_log_mostrado on public.reforco_log (conversa_id, sinal, dia) where modo = 'so_mostrado';
create index if not exists reforco_log_conversa on public.reforco_log (conversa_id, em desc);
alter table public.reforco_log enable row level security;
drop policy if exists reforco_log_ler on public.reforco_log;
create policy reforco_log_ler on public.reforco_log for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke insert, update, delete on public.reforco_log from anon, authenticated;

create or replace function public._reforco_norm(p text) returns text language sql immutable as $$
  select btrim(regexp_replace(lower(coalesce(p, '')), '[^[:alnum:]áàâãéêíóôõúç]+', ' ', 'g'))
$$;

-- ───────────── a lista da faixa (chamada por dentro da live2_fila) ─────────────
create or replace function public._live2_reforco()
returns jsonb
language plpgsql
stable security definer
set search_path = public
as $$
declare
  p      jsonb := coalesce((select valor from public.config_regras where chave = 'reforco_sinais'), '{}'::jsonb);
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_esc  interval := make_interval(hours => coalesce((p ->> 'escorregou_horas')::int, 2));
  v_cal  interval := make_interval(mins => coalesce((p ->> 'mari_calada_min')::int, 3));
  r      jsonb;
begin
  with base as (
    select c.id, coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
           c.cidade, c.funil_etapa, c.plano_escolhido, c.dados, c.ultima_msg_lead_at, c.ultima_msg_mari_at,
           (case when coalesce(c.cep, '') <> '' then 1 else 0 end + case when coalesce(c.numero, '') <> '' then 1 else 0 end
            + case when c.plano_escolhido is not null then 1 else 0 end + case when c.forma_pagamento is not null then 1 else 0 end
            + case when coalesce(c.dados ->> 'nome', '') <> '' then 1 else 0 end + case when coalesce(c.dados ->> 'cpf', '') <> '' then 1 else 0 end
            + case when coalesce(c.dados ->> 'email', '') <> '' then 1 else 0 end
            + case when coalesce(c.nio_viab_resultado, '') = 'viavel' then 1 else 0 end) as n_dados
      from public.mari_conversas c
      join public.lead_estado e on e.conversa_id = c.id and e.venda_id is null and e.situacao = 'mari_atendendo'
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
       and not coalesce(c.nao_contatar, false) and c.venda_id is null
       and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and c.ultima_msg_lead_at > now() - interval '23 hours'
       and not exists (select 1 from public.reforco_log g where g.conversa_id = c.id
                        and ((g.modo in ('soprar', 'assumir') and g.em > now() - make_interval(hours => coalesce((p ->> 'descanso_horas')::int, 2)))
                          or (g.modo = 'agora_nao' and g.em > now() - make_interval(hours => coalesce((p ->> 'agora_nao_horas')::int, 24)))))
  ),
  sin as (
    select b.*,
           uf.texto as fala, uf.created_at as fala_em,
           -- a Mari escorregou
           (exists (select 1 from public.mari_turnos t1 join public.mari_turnos t2 on t2.conversa_id = t1.conversa_id and t2.id > t1.id
                     where t1.conversa_id = b.id and t1.papel = 'lead' and t2.papel = 'lead' and t2.created_at > now() - v_esc
                       and t1.created_at > now() - v_esc and length(public._reforco_norm(t1.texto)) >= 8
                       and public._reforco_norm(t1.texto) = public._reforco_norm(t2.texto))) as esc_cliente_repetiu,
           (exists (select 1 from public.mari_turnos t1 join public.mari_turnos t2 on t2.conversa_id = t1.conversa_id and t2.id > t1.id
                     where t1.conversa_id = b.id and t1.papel = 'mari' and t2.papel = 'mari' and t2.created_at > now() - v_esc
                       and t1.created_at > now() - v_esc and length(public._reforco_norm(t1.texto)) >= 20
                       and public._reforco_norm(t1.texto) = public._reforco_norm(t2.texto))) as esc_mari_repetiu,
           (exists (select 1 from public.mari_turnos t where t.conversa_id = b.id and t.papel = 'lead' and t.created_at > now() - v_esc
                       and t.texto ~* '(n[aã]o entendi|j[aá] (te |lhe )?(falei|disse|respondi|informei|mandei|passei)|n[aã]o foi isso|n[aã]o [eé] isso|voc[eê] n[aã]o (respondeu|entendeu|leu))')) as esc_reclamou,
           (ult.n_lead >= 2 and ult.mais_velha < now() - v_cal and ult.mais_nova < now() - v_cal) as esc_mari_calada,
           (b.dados ->> 'objecao' in (select jsonb_array_elements_text(coalesce(p -> 'objecoes', '[]'::jsonb)))
             and b.ultima_msg_lead_at > now() - make_interval(hours => coalesce((p ->> 'objecao_horas')::int, 2))) as s_objecao,
           (b.funil_etapa in (select jsonb_array_elements_text(coalesce(p -> 'etapas', '[]'::jsonb)))
             and (select count(*) from public.mari_turnos t where t.conversa_id = b.id and t.papel = 'lead' and t.created_at > now() - interval '1 hour')
                 >= coalesce((p ->> 'quente_falas')::int, 3)) as s_quente,
           (b.n_dados >= coalesce((p ->> 'pronto_min')::int, 6)) as s_pronto,
           (b.funil_etapa in ('viu_planos', 'viavel') and b.ultima_msg_mari_at > b.ultima_msg_lead_at
             and b.ultima_msg_mari_at < now() - make_interval(mins => coalesce((p ->> 'sumiu_min')::int, 20))
             and b.ultima_msg_mari_at > now() - make_interval(mins => coalesce((p ->> 'sumiu_max_min')::int, 180))) as s_sumiu
      from base b
      left join lateral (select left(regexp_replace(coalesce(t.texto, ''), '\s+', ' ', 'g'), 220) as texto, t.created_at
                           from public.mari_turnos t where t.conversa_id = b.id and t.papel = 'lead' order by t.created_at desc limit 1) uf on true
      -- as duas últimas falas da conversa são do cliente? (a Mari não respondeu)
      left join lateral (select count(*) filter (where z.papel = 'lead') as n_lead, min(z.created_at) as mais_velha, max(z.created_at) as mais_nova
                           from (select t.papel, t.created_at from public.mari_turnos t
                                  where t.conversa_id = b.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 2) z) ult on true
  ),
  sel as (
    select s.*, (s.esc_cliente_repetiu or s.esc_mari_repetiu or s.esc_reclamou or s.esc_mari_calada) as s_escorregou
      from sin s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id', s.id, 'k', 'c:' || s.id::text, 'nome', s.nome, 'cidade', s.cidade, 'etapa', s.funil_etapa,
           'plano', coalesce(pl.nome_curto, pl.nome), 'vale', pl.comissao + coalesce(bo.valor, 0),
           'sinal', case when s.s_escorregou then 'escorregou' when s.s_objecao then 'objecao' when s.s_quente then 'quente'
                         when s.s_pronto then 'pronto' else 'sumiu' end,
           'sinais', to_jsonb(array_remove(array[case when s.s_escorregou then 'escorregou' end, case when s.s_objecao then 'objecao' end,
                         case when s.s_quente then 'quente' end, case when s.s_pronto then 'pronto' end, case when s.s_sumiu then 'sumiu' end], null)),
           'porque', case when s.esc_reclamou then 'O cliente disse que não foi entendido'
                          when s.esc_cliente_repetiu then 'O cliente repetiu a mesma pergunta'
                          when s.esc_mari_repetiu then 'A Mari repetiu a mesma fala'
                          when s.esc_mari_calada then 'O cliente falou duas vezes e a Mari não respondeu'
                          when s.s_objecao then 'Objeção: ' || case s.dados ->> 'objecao' when 'preco' then 'preço' when 'pensar' then 'vai pensar'
                                                    when 'concorrente' then 'concorrente' when 'consultar_alguem' then 'precisa consultar alguém' else s.dados ->> 'objecao' end
                          when s.s_quente then 'Cliente quente: várias falas na última hora'
                          when s.s_pronto then format('Quase pronto: %s de 8 dados da venda já coletados', s.n_dados)
                          else 'Viu os planos e ficou calado' end,
           'fala', s.fala, 'fala_em', s.fala_em,
           'janela_fecha_em', s.ultima_msg_lead_at + interval '24 hours')
           order by (case when s.s_escorregou then 0 when s.s_objecao then 1 when s.s_quente then 2 when s.s_pronto then 3 else 4 end),
                    s.ultima_msg_lead_at desc), '[]'::jsonb)
    into r
    from sel s
    left join public.config_planos pl on pl.codigo = s.plano_escolhido
    left join lateral (select b.valor from public.config_bonus b where b.tipo = 'transicao' and b.cluster = pl.cluster
                         and b.valido_de <= v_hoje and (b.valido_ate is null or b.valido_ate >= v_hoje) limit 1) bo on true
   where s.s_escorregou or s.s_objecao or s.s_quente or s.s_pronto or s.s_sumiu;
  return r;
end $$;
revoke all on function public._live2_reforco() from public, anon, authenticated;
revoke all on function public._reforco_norm(text) from public, anon;
grant execute on function public._reforco_norm(text) to authenticated, service_role;

-- ───────────── o que o gerente faz com cada linha ─────────────
create or replace function public._reforco_gravar(p_conversa uuid, p_sinal text, p_modo text, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.reforco_log (conversa_id, sinal, modo, motivo, etapa, por)
  select c.id, left(coalesce(nullif(btrim(p_sinal), ''), 'sem_sinal'), 40), p_modo, nullif(left(btrim(coalesce(p_motivo, '')), 200), ''), c.funil_etapa, auth.uid()
    from public.mari_conversas c where c.id = p_conversa
  on conflict do nothing;
end $$;
revoke all on function public._reforco_gravar(uuid, text, text, text) from public, anon, authenticated;

-- Soprar: a mensagem sai pela porta (mari_soprar, com todas as recusas dela) e o reforço fica registrado
create or replace function public.reforco_soprar(p_conversa uuid, p_sinal text, p_texto text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice reforça uma conversa.' using errcode = '42501';
  end if;
  r := public.mari_soprar(p_conversa, p_texto);
  perform public._reforco_gravar(p_conversa, p_sinal, 'soprar', null);
  return r;
end $$;
revoke all on function public.reforco_soprar(uuid, text, text) from public, anon;
grant execute on function public.reforco_soprar(uuid, text, text) to authenticated;

-- Assumir (depois de o time assumir pelo caminho de sempre) e Agora não (com motivo): só o registro
create or replace function public.reforco_registrar(p_conversa uuid, p_sinal text, p_modo text, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  if p_modo not in ('assumir', 'agora_nao') then
    raise exception 'Modo inválido: %', p_modo;
  end if;
  perform public._reforco_gravar(p_conversa, p_sinal, p_modo, p_motivo);
  return jsonb_build_object('ok', true, 'resumo', case p_modo when 'agora_nao' then 'Fora do Reforço por 24 h' else 'Reforço registrado: você assumiu' end);
end $$;
revoke all on function public.reforco_registrar(uuid, text, text, text) from public, anon;
grant execute on function public.reforco_registrar(uuid, text, text, text) to authenticated;

-- O grupo de comparação: a linha apareceu para alguém (uma vez por conversa, sinal e dia)
create or replace function public.reforco_mostrados(p_itens jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; x jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return 0; end if;
  for x in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) limit 60 loop
    perform public._reforco_gravar((x ->> 'conversa_id')::uuid, x ->> 'sinal', 'so_mostrado', null);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.reforco_mostrados(jsonb) from public, anon;
grant execute on function public.reforco_mostrados(jsonb) to authenticated;

-- ───────────── o desfecho, por sinal e modo ─────────────
create or replace function public.reforco_resultado(p_dias int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return null; end if;
  with casos as (
    select g.conversa_id, g.sinal, min(g.em) as em,
           coalesce((array_agg(g.modo order by g.em) filter (where g.modo <> 'so_mostrado'))[1], 'so_mostrado') as modo
      from public.reforco_log g
     where g.em > now() - make_interval(days => greatest(1, coalesce(p_dias, 30)))
     group by g.conversa_id, g.sinal
  ),
  d as (
    select k.sinal, k.modo,
           exists (select 1 from public.mari_turnos t where t.conversa_id = k.conversa_id and t.papel = 'lead'
                    and t.created_at > k.em and t.created_at <= k.em + interval '24 hours') as respondeu,
           (v.id is not null and v.criado_em > k.em) as virou_venda,
           (v.id is not null and v.criado_em > k.em and coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) is not null) as com_pedido,
           (coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada')) as saiu
      from casos k
      join public.mari_conversas c on c.id = k.conversa_id
      left join public.vendas v on v.id = c.venda_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('sinal', sinal, 'modo', modo, 'n', n, 'respondeu_24h', respondeu,
           'virou_venda', virou_venda, 'com_pedido', com_pedido, 'saiu', saiu) order by sinal, modo), '[]'::jsonb)
    into r
    from (select sinal, modo, count(*) as n, count(*) filter (where respondeu) as respondeu, count(*) filter (where virou_venda) as virou_venda,
                 count(*) filter (where com_pedido) as com_pedido, count(*) filter (where saiu) as saiu
            from d group by sinal, modo) z;
  return r;
end $$;
revoke all on function public.reforco_resultado(int) from public, anon;
grant execute on function public.reforco_resultado(int) to authenticated, service_role;

commit;
