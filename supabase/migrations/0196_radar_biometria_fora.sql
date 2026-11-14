-- NIOGEN | supabase/migrations/0196_radar_biometria_fora.sql | 14/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 14/11: "o sistema de biometria da Nio para de funcionar com frequência (o Rogério avisa no grupo) e, com a volta,
-- os parceiros mandam uma enxurrada de pedidos… deixar no radar essas biometrias paradas e conseguir inputar essas vendas."
-- Decisões dele (14/11): sinal automático + botão manual · com o sistema fora, a Nio LIBERA a venda da biometria (o time marca por
-- venda; vale como aprovada: comissão normal e, no cartão, o link do cadastro do cartão sai logo) · liberado não refaz depois ·
-- quando volta, a Mari avisa quem ficou esperando e o Live prioriza · medição no Painel e em Operações.
-- O que muda:
--   biometria_quedas ............ cada queda (auto = GED360 sem biometria nova há N h no horário comercial; manual = o time marcou).
--   biometria_queda_conferir() .. roda no fim de cada leitura do GED360 (15 min): abre a suspeita e fecha quando volta biometria nova.
--   biometria_queda_marcar() .... botões "Biometria da Nio fora do ar" / "Voltou" (admin/backoffice), com autor.
--   biometria_radar() ........... números do Painel e de Operações (paradas agora, tempo OS → biometria, dispensadas, por dia).
--   backoffice_momento .......... biometria → 'dispensada' (vendas.biometria_dispensada_em/por/motivo, evento biometria_dispensada).
--   cadência .................... passo BIOVOLTA (texto mari_bio_voltou, só na janela de 24 h) para quem esperou durante a queda.
--   live_conferir / v_jornada ... a queda no ⚠ Conferir; durante ela "pedir a dispensa"; depois dela, "voltou" em vermelho.
-- Regra 20: a queda tem dono (time), prazo (fecha sozinha com biometria nova no GED360) e aparece no Live enquanto aberta; muda só por
-- função do banco, com autor. A dispensa é um momento do backoffice com motivo e autor.

begin;
set local lock_timeout = '8s';

create table if not exists public.biometria_quedas (
  id               bigint generated always as identity primary key,
  parceiro_id      text not null default 'dharma',
  inicio           timestamptz not null,               -- auto: a última biometria antes do silêncio · manual: a hora da marcação
  aberta_em        timestamptz not null default now(),
  origem           text not null check (origem in ('auto', 'manual')),
  horas_sem_envio  numeric,
  ultima_envio_antes timestamptz,
  aberta_por       uuid,
  confirmada_em    timestamptz,
  confirmada_por   uuid,
  fim              timestamptz,
  fechada_como     text check (fechada_como in ('auto', 'manual')),
  fechada_por      uuid,
  obs              text
);
create index if not exists biometria_quedas_aberta_idx on public.biometria_quedas (fim) where fim is null;
alter table public.biometria_quedas enable row level security;
drop policy if exists biometria_quedas_ler on public.biometria_quedas;
create policy biometria_quedas_ler on public.biometria_quedas for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
comment on table public.biometria_quedas is '0196: quedas do sistema de biometria da Nio (auto pelo GED360 ou marcadas pelo time).';

alter table public.vendas add column if not exists biometria_dispensada_em timestamptz;
alter table public.vendas add column if not exists biometria_dispensada_por uuid;
alter table public.vendas add column if not exists biometria_dispensa_motivo text;
alter table public.mari_conversas add column if not exists bio_volta_em timestamptz;

insert into public.config_regras (chave, valor, descricao, parceiro_id)
values ('biometria_queda', '{"horas_sem_envio": 3, "novas_para_fechar_manual": 3}'::jsonb,
        '0196: GED360 sem biometria nova há N h (com as N h inteiras no horário comercial) = suspeita de biometria da Nio fora do ar; a marcada à mão fecha sozinha com X biometrias novas.', 'dharma')
on conflict (chave) do nothing;

insert into public.config_mari_textos (chave, texto) values ('mari_bio_voltou',
'Oi, {nome}! O sistema de biometria da Nio voltou a funcionar 😊

Se o link da biometria ainda não chegou ou expirou, me avisa por aqui que a gente pede um novo. Se já chegou, é só fazer: é rapidinho e é ele que confirma a visita do técnico.')
on conflict (chave) do update set texto = excluded.texto, atualizado_em = now();

create or replace function public.biometria_queda_conferir()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  cfg  jsonb := coalesce((select valor from public.config_regras where chave = 'biometria_queda'), '{}'::jsonb);
  h    numeric := coalesce((cfg ->> 'horas_sem_envio')::numeric, 3);
  nf   int := coalesce((cfg ->> 'novas_para_fechar_manual')::int, 3);
  ult  timestamptz;
  q    public.biometria_quedas;
begin
  select max(data_envio) into ult from public.nio_biometria where parceiro_id = 'dharma';
  if ult is null then return; end if;
  select * into q from public.biometria_quedas where fim is null order by inicio desc limit 1;
  if q.id is not null then
    -- Voltou: biometria nova no GED360 depois do início (a marcada à mão espera algumas, para não fechar com uma isolada).
    if (q.origem = 'auto' and ult > q.inicio)
       or (q.origem = 'manual' and (select count(*) from public.nio_biometria b where b.data_envio > q.inicio) >= nf) then
      update public.biometria_quedas set fim = now(), fechada_como = 'auto' where id = q.id;
    end if;
    return;
  end if;
  if ult < now() - make_interval(mins => (h * 60)::int)
     and public.mari_no_horario(now(), null) and public.mari_no_horario(now() - make_interval(mins => (h * 60)::int), null)
     and not exists (select 1 from public.biometria_quedas x where x.fim > now() - interval '2 hours')
     and not exists (select 1 from public.biometria_quedas x where x.inicio = ult) then
    insert into public.biometria_quedas (inicio, origem, horas_sem_envio, ultima_envio_antes) values (ult, 'auto', h, ult);
  end if;
end;
$function$;
revoke all on function public.biometria_queda_conferir() from public, anon, authenticated;

create or replace function public.biometria_queda_marcar(p_acao text, p_obs text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  q public.biometria_quedas;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice marca a biometria da Nio.' using errcode = '42501';
  end if;
  select * into q from public.biometria_quedas where fim is null order by inicio desc limit 1;
  if p_acao = 'fora' then
    if q.id is not null then
      update public.biometria_quedas set confirmada_em = coalesce(confirmada_em, now()), confirmada_por = coalesce(confirmada_por, auth.uid()),
             obs = coalesce(nullif(btrim(p_obs), ''), obs) where id = q.id;
      return jsonb_build_object('ok', true, 'resumo', 'queda confirmada (já estava no radar desde ' || to_char(q.inicio at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ')');
    end if;
    insert into public.biometria_quedas (inicio, origem, aberta_por, confirmada_em, confirmada_por, obs)
    values (now(), 'manual', auth.uid(), now(), auth.uid(), nullif(btrim(p_obs), ''));
    return jsonb_build_object('ok', true, 'resumo', 'biometria da Nio marcada como fora do ar');
  elsif p_acao = 'voltou' then
    if q.id is null then return jsonb_build_object('ok', true, 'resumo', 'não havia queda aberta'); end if;
    update public.biometria_quedas set fim = now(), fechada_como = 'manual', fechada_por = auth.uid(),
           obs = coalesce(nullif(btrim(p_obs), ''), obs) where id = q.id;
    return jsonb_build_object('ok', true, 'resumo', 'biometria da Nio de volta — a Mari avisa quem ficou esperando e o Live prioriza');
  end if;
  raise exception 'Use fora ou voltou.';
end;
$function$;
revoke all on function public.biometria_queda_marcar(text, text) from public, anon;
grant execute on function public.biometria_queda_marcar(text, text) to authenticated;

create or replace function public.biometria_radar()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return null; end if;
  select jsonb_build_object(
    'queda', (select to_jsonb(q) - 'aberta_por' - 'confirmada_por' - 'fechada_por'
                 || jsonb_build_object('quem', (select u.nome from public.usuarios u where u.id = coalesce(q.confirmada_por, q.aberta_por)))
                from public.biometria_quedas q where q.fim is null order by q.inicio desc limit 1),
    'quedas', coalesce((select jsonb_agg(jsonb_build_object('inicio', q.inicio, 'fim', q.fim, 'origem', q.origem,
                 'confirmada', q.confirmada_em is not null, 'horas', round(extract(epoch from coalesce(q.fim, now()) - q.inicio) / 3600, 1)) order by q.inicio desc)
                from public.biometria_quedas q where q.inicio > now() - interval '30 days'), '[]'::jsonb),
    'paradas', (select count(*) from public.vendas v where v.status in ('1_vendido', '2_aguardando_instalacao') and v.biometria_status in ('pendente', 'com_risco')),
    'paradas_24h', (select count(*) from public.vendas v where v.status in ('1_vendido', '2_aguardando_instalacao') and v.biometria_status in ('pendente', 'com_risco')
                      and coalesce(v.biometria_link_enviado_em, v.nio_os_em) < now() - interval '24 hours'),
    'mediana_os_bio_h', (select round((percentile_cont(0.5) within group (order by extract(epoch from v.biometria_validada_em - v.nio_os_em) / 3600))::numeric, 1)
                           from public.vendas v where v.nio_os_em is not null and v.biometria_validada_em >= v.nio_os_em
                            and v.biometria_dispensada_em is null and v.nio_os_em > now() - interval '30 days'),
    'medidas', (select count(*) from public.vendas v where v.nio_os_em is not null and v.biometria_validada_em >= v.nio_os_em
                  and v.biometria_dispensada_em is null and v.nio_os_em > now() - interval '30 days'),
    'dispensadas_30d', (select count(*) from public.vendas v where v.biometria_dispensada_em > now() - interval '30 days'),
    'por_dia', coalesce((select jsonb_agg(x order by x ->> 'dia') from (
        select jsonb_build_object('dia', to_char(date_trunc('day', b.data_envio at time zone 'America/Sao_Paulo'), 'YYYY-MM-DD'),
               'enviadas', count(*),
               'aprovadas', count(*) filter (where c.acao = 'aprovada'),
               'expiradas', count(*) filter (where b.resultado = 'LINK EXPIRADO'),
               'so_link', count(*) filter (where b.resultado = 'LINK ENVIADO')) as x
          from public.nio_biometria b
          left join public.config_biometria_resultado c on c.parceiro_id = b.parceiro_id and c.resultado = b.resultado
         where b.data_envio > now() - interval '14 days'
         group by date_trunc('day', b.data_envio at time zone 'America/Sao_Paulo')) z), '[]'::jsonb),
    'ultima_envio', (select max(data_envio) from public.nio_biometria))
  into r;
  return r;
end;
$function$;
revoke all on function public.biometria_radar() from public, anon;
grant execute on function public.biometria_radar() to authenticated;

CREATE OR REPLACE FUNCTION public.ged360_registrar(p_linhas jsonb, p_erro text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r     jsonb;
  prot  text;
  res   text;
  ant   public.nio_biometria;
  b     public.nio_biometria;
  ap    jsonb;
  novo  boolean;
  n     int := 0;
  mud   int := 0;
  vid   uuid;
  desc_ text[] := '{}';
begin
  if p_erro is not null then
    insert into public.ged360_leituras (ok, erro) values (false, left(p_erro, 300));
    return jsonb_build_object('ok', false, 'erro', p_erro);
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    prot := btrim(coalesce(r ->> 'protocolo', ''));
    res := upper(btrim(regexp_replace(coalesce(r ->> 'resultado', ''), '\s+', ' ', 'g')));
    if prot = '' then continue; end if;
    n := n + 1;
    select * into ant from public.nio_biometria where parceiro_id = 'dharma' and protocolo = prot for update;
    novo := not found;
    insert into public.nio_biometria as t (protocolo, cpf_cnpj, data_envio, data_conferencia, tipo_servico, resultado, desconhecido)
    values (prot, public._so_digitos(r ->> 'cpf_cnpj'), public._br_ts(r ->> 'data_envio'), public._br_ts(r ->> 'data_conferencia'),
            nullif(btrim(r ->> 'tipo_servico'), ''), nullif(res, ''),
            nullif(res, '') is not null and not exists (select 1 from public.config_biometria_resultado c where c.parceiro_id = 'dharma' and c.resultado = res))
    on conflict (parceiro_id, protocolo) do update set
      cpf_cnpj = coalesce(excluded.cpf_cnpj, t.cpf_cnpj), data_envio = coalesce(excluded.data_envio, t.data_envio),
      data_conferencia = coalesce(excluded.data_conferencia, t.data_conferencia), tipo_servico = excluded.tipo_servico,
      resultado_desde = case when t.resultado is distinct from excluded.resultado then now() else t.resultado_desde end,
      resultado = coalesce(excluded.resultado, t.resultado), desconhecido = excluded.desconhecido, ultima_leitura = now()
    returning * into b;
    if b.desconhecido and (novo or ant.resultado is distinct from b.resultado) then
      desc_ := desc_ || b.resultado;
    end if;
  end loop;

  -- Casar pelo CPF (só dígitos) com a venda de pedido aberto (antes da instalação); nunca pelo nome.
  update public.nio_biometria nb set venda_id = x.venda_id
  from (select distinct on (nb2.id) nb2.id, v.id as venda_id
          from public.nio_biometria nb2
          join public.vendas v on public._so_digitos(v.cliente_cpf_cnpj) = nb2.cpf_cnpj
         where nb2.venda_id is null and nb2.cpf_cnpj is not null and v.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')
         order by nb2.id, v.criado_em desc) x
  where nb.id = x.id;

  -- Para cada venda, vale o protocolo de Data de Envio mais recente; aplica o mapa quando o resultado mudou (ou casou agora).
  for b in
    select distinct on (venda_id) * from public.nio_biometria
     where venda_id is not null and (ultima_leitura > now() - interval '5 minutes')
     order by venda_id, data_envio desc nulls last, id desc
  loop
    if b.desconhecido then continue; end if;
    if exists (select 1 from public.eventos_venda e where e.venda_id = b.venda_id and e.tipo = 'biometria_ged360'
                and e.detalhe ->> 'protocolo' = b.protocolo and e.detalhe ->> 'para' = b.resultado) then
      continue;   -- já aplicado
    end if;
    mud := mud + 1;
    insert into public.eventos_venda (venda_id, tipo, detalhe)
    values (b.venda_id, 'biometria_ged360', jsonb_build_object('protocolo', b.protocolo, 'para', b.resultado,
            'envio', b.data_envio, 'conferencia', b.data_conferencia));
    ap := public._ged360_aplicar(b);
    update public.nio_biometria set alerta = ap ->> 'alerta', alerta_nivel = ap ->> 'nivel',
      alerta_em = case when ap ->> 'alerta' is null then null else now() end, alerta_visto_em = null
    where id = b.id;
  end loop;
  -- Sem venda: os alertas valem igual (pendência "biometria sem venda" mostra o resultado).
  update public.nio_biometria nb set alerta = c.texto, alerta_nivel = c.nivel, alerta_em = coalesce(nb.alerta_em, now())
    from public.config_biometria_resultado c
   where nb.venda_id is null and c.parceiro_id = nb.parceiro_id and c.resultado = nb.resultado and c.acao in ('alerta', 'risco')
     and nb.alerta is null and nb.alerta_visto_em is null;

  if array_length(desc_, 1) > 0 then
    insert into public.mari_erros (no_n8n, mensagem, payload)
    values ('ged360_desconhecido', 'GED360: resultado novo fora do mapa (config_biometria_resultado) — completar o mapa',
            jsonb_build_object('resultados', to_jsonb(desc_)));
  end if;
  insert into public.ged360_leituras (ok, linhas, mudancas) values (true, n, mud);
  perform public.biometria_queda_conferir();   -- 0196: radar da biometria da Nio fora do ar
  return jsonb_build_object('ok', true, 'linhas', n, 'mudancas', mud, 'desconhecidos', to_jsonb(desc_));
end;
$function$;

CREATE OR REPLACE FUNCTION public.backoffice_momento(p_venda uuid, p_momento text, p_dados jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d        jsonb := coalesce(p_dados, '{}'::jsonb);
  v        public.vendas;
  c        public.mari_conversas;
  tem_cw   boolean := false;
  g        uuid := gen_random_uuid();
  o        int := 0;
  quem     text;
  agente   int;
  v_time   int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  agora_t  text := to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI');
  feito    text[] := '{}';
  aviso    text;
  msg      jsonb;
  quando   timestamptz;
  v_res    text;
  v_dia    date;
  v_per    text;
  v_ts     timestamptz;
  v_turno  text;
  v_diatxt text;
  v_pertxt text;
  v_ped    text;
  v_os     text;
  v_tinha  boolean;
  v_forma  text;
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
  r        jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice usa os botões da venda.' using errcode = '42501';
  end if;
  if p_momento = 'reagendar' then p_momento := 'agendar'; end if;   -- 0096: agendar e reagendar são o mesmo passo
  if p_momento not in ('assumir', 'viabilidade', 'credito', 'pedido', 'biometria', 'os', 'agendar', 'os_agendar', 'parar', 'devolver_mari') then
    raise exception 'Momento desconhecido: %', p_momento;
  end if;
  select nome, chatwoot_agente_id into quem, agente from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  if p_venda is not null then
    select * into v from public.vendas where id = p_venda for update;
    if not found then raise exception 'Venda não encontrada.'; end if;
    select * into c from public.mari_conversas
     where venda_id = p_venda and canal = 'whatsapp' and coalesce(chatwoot_conversation_id, '') <> ''
     order by created_at desc limit 1;
  elsif d ? 'conversa_id' then
    select * into c from public.mari_conversas where id = (d ->> 'conversa_id')::uuid;
    if not found then raise exception 'Conversa não encontrada.'; end if;
    if c.venda_id is not null then select * into v from public.vendas where id = c.venda_id; end if;
  else
    raise exception 'Informe a venda ou a conversa.';
  end if;
  if p_momento in ('viabilidade', 'credito', 'pedido', 'biometria', 'os', 'agendar', 'os_agendar') and v.id is null then
    raise exception 'Este botão precisa de uma venda.';
  end if;
  tem_cw := c.id is not null and c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
            and c.telefone not like '5500000000%';

  -- ── assumir ──
  if p_momento = 'assumir' then
    if c.id is null then raise exception 'Esta venda não tem conversa no Chatwoot para assumir.'; end if;
    if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'atribuir'
                and a.status in ('pendente', 'executando', 'feita') and a.criada_em > now() - interval '10 minutes') then
      return jsonb_build_object('ok', true, 'momento', p_momento, 'acoes', 0, 'feito', jsonb_build_array('já assumida há instantes'),
                                'resumo', '✓ esta conversa já foi assumida há instantes — nada repetido', 'venda_id', v.id, 'conversa_id', c.id);
    end if;
    perform public.mari_cadencia_parar(c.id, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[assumida no NIOGEN por ' || quem || ' — cadência parada]', false);
    if v.id is not null and v.vendedor_id is null then
      update public.vendas set vendedor_id = auth.uid() where id = v.id;
    end if;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'atribuir',
        case when agente is not null then jsonb_build_object('assignee_id', agente) else jsonb_build_object('team_id', v_time) end);
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '👤 Assumida no NIOGEN por ' || quem || ' às ' || agora_t || '.'));
      feito := feito || array[case when agente is not null then 'conversa atribuída a você' else 'conversa no time backoffice' end, 'nota']::text[];
    end if;
    feito := feito || 'Mari calada · cadência parada'::text;

  -- ── viabilidade (portal) ──
  elsif p_momento = 'viabilidade' then
    v_res := nullif(d ->> 'resultado', '');
    if v_res is not null and v_res not in ('viavel', 'sem_viabilidade', 'nao_encontrado') then
      raise exception 'Resultado do portal inválido.';
    end if;
    update public.vendas set
      nio_viab_resultado = v_res, nio_viab_origem = case when v_res is null then null else 'manual' end,
      nio_viab_em = case when v_res is null then null else now() end,
      nio_viab_velocidade = nullif(btrim(coalesce(d ->> 'velocidade', '')), ''),
      nio_viab_interesse_id = nullif(btrim(coalesce(d ->> 'interesse', '')), ''),
      nio_viab_endereco_portal = nullif(btrim(coalesce(d ->> 'endereco_portal', '')), '')
    where id = v.id;
    feito := feito || 'viabilidade gravada'::text;
    if tem_cw and v_res is not null then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota', jsonb_build_object('content',
        '📍 Viabilidade no portal: ' || case v_res when 'viavel' then 'Viável' when 'sem_viabilidade' then 'Sem viabilidade' else 'Endereço não encontrado' end
        || coalesce(' (' || nullif(btrim(coalesce(d ->> 'velocidade', '')), '') || ')', '') || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
    end if;
    if v_res in ('sem_viabilidade', 'nao_encontrado') then
      aviso := 'Tente variações de CEP, rua e número. Se só a Nio pode confirmar, abra a pendência "Nio confirmar viabilidade".';
    end if;

  -- ── pedido gravado no portal (etapa 3): SÓ o pedido; a Nio manda o link da biometria (0089) ──
  elsif p_momento = 'pedido' then
    v_ped := btrim(coalesce(d ->> 'pedido', ''));
    if v_ped !~ '^[A-Za-z0-9._/-]{4,40}$' then
      raise exception 'Número do pedido inválido: use só letras, números, ponto, barra ou hífen (4 a 40 caracteres).' using errcode = '22023';
    end if;
    if v.status = 'saida' then raise exception 'A venda está em Saída; reabra pela ficha antes de registrar o pedido.'; end if;
    if v.status <> '0_qualificado' then raise exception 'O pedido já foi gravado e a venda já andou.'; end if;
    if d ? 'link' and coalesce(d ->> 'link', '') <> '' and (d ->> 'link') !~* '^https?://' then
      raise exception 'O link da biometria tem que começar com https://';
    end if;
    if v.nio_pedido is not distinct from v_ped then
      update public.vendas set credito_resultado = coalesce(nullif(d ->> 'credito', ''), credito_resultado),
             biometria_link = coalesce(nullif(btrim(coalesce(d ->> 'link', '')), ''), biometria_link) where id = v.id;
      return jsonb_build_object('ok', true, 'momento', p_momento, 'acoes', 0, 'feito', jsonb_build_array('pedido já estava gravado'),
                                'resumo', '✓ pedido nº ' || v_ped || ' já estava gravado — nada foi reenviado ao cliente', 'venda_id', v.id);
    end if;
    -- O trigger 0032 carimba nio_pedido_em e a biometria pendente (as 24 h / 72 h contam dali).
    update public.vendas set
      nio_pedido = v_ped,
      credito_resultado = coalesce(nullif(d ->> 'credito', ''), credito_resultado),
      biometria_link = coalesce(nullif(btrim(coalesce(d ->> 'link', '')), ''), biometria_link)
    where id = v.id;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'pedido_aberto_portal', jsonb_build_object('origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'), 'pedido', v_ped), auth.uid());
    feito := feito || 'pedido gravado · etapa Pedido · biometria'::text;
    if not (v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days') then
      aviso := 'Registre a viabilidade do portal (Viável): sem ela a venda não conta.';
    end if;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 Pedido nº ' || v_ped || ' aberto às ' || agora_t || ' — ' || quem || '. A Nio manda o link da biometria ao cliente.'));
      if coalesce((d ->> 'sem_aviso')::boolean, false) then
        feito := feito || 'etiqueta'::text || 'nota'::text || 'sem aviso ao cliente (o time já avisou)'::text;   -- 0092
      else
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_pedido_biometria', '{}'::jsonb,
                                   'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do pedido (biometria)');
        feito := feito || 'etiqueta'::text || 'nota'::text;
      end if;
    end if;

  -- ── crédito no portal (0092: registrado da extensão, na etapa do cadastro) ──
  elsif p_momento = 'credito' then
    v_res := d ->> 'resultado';
    if v_res not in ('aprovado', 'so_cartao', 'pendente', 'negado') then raise exception 'Crédito: use aprovado, só cartão, pendente ou negado.'; end if;
    if v.status = 'saida' then raise exception 'A venda está em Saída.'; end if;
    v_tinha := coalesce(v.credito_resultado, '') in ('aprovado', 'so_cartao') or coalesce(btrim(v.nio_pedido), '') <> '';
    update public.vendas set credito_resultado = v_res where id = v.id;
    feito := feito || ('crédito ' || case v_res when 'aprovado' then 'aprovado' when 'so_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente' else 'negado' end)::text;
    -- 0191 (Ricardo, 14/11): crédito aprovado só libera seguir o pedido no portal (forma de pagamento → agenda → OS).
    -- O link da biometria sai DEPOIS da OS: o aviso ao cliente e os lembretes partem de "Gravar OS e agenda".
    if v_res in ('aprovado', 'so_cartao') and v.status = '0_qualificado' and not v_tinha then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'credito_aprovado_portal', jsonb_build_object('origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'), 'resultado', v_res), auth.uid());
      feito := feito || 'próximo: forma de pagamento, agenda e OS no portal'::text;
      if not (v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days') then
        aviso := 'Registre a viabilidade do portal (Viável): sem ela a venda não conta.';
      end if;
    end if;
    if v_res = 'negado' then
      if not exists (select 1 from public.venda_pendencias where venda_id = v.id and encerrada_em is null)
         and exists (select 1 from public.config_motivos_pendencia where codigo = 'credito_outro_cpf' and ativo) then
        v_dia := (now() at time zone 'America/Sao_Paulo')::date + 1;
        while extract(isodow from v_dia) = 7 loop v_dia := v_dia + 1; end loop;
        perform public.pendencia_abrir(v.id, 'credito_outro_cpf', null, v_dia);
        feito := feito || 'pendência aberta (outro CPF)'::text;
      end if;
    end if;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota', jsonb_build_object('content',
        '💳 Crédito no portal: ' || case v_res when 'aprovado' then 'aprovado — próximo: forma de pagamento, agenda e OS' when 'so_cartao' then 'aprovado só no cartão — próximo: agenda e OS (cartão)' when 'pendente' then 'pendente (24 h)' else 'negado — pedido outro CPF' end
        || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
      if v_res = 'negado' then
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
      end if;
    end if;
    if v_res = 'so_cartao' and coalesce(v.forma_pagamento, '') <> 'cartao' then
      aviso := 'Aprovado só no cartão: troque a forma de pagamento na ficha (Detalhes › Plano, valor e pagamento › Trocar).';
    end if;

  -- ── biometria (Validada · Risco · Negado) — etapa 3 ──
  elsif p_momento = 'biometria' then
    if coalesce(btrim(v.nio_pedido), '') = '' and coalesce(v.credito_resultado, '') not in ('aprovado', 'so_cartao') then
      raise exception 'Grave antes o crédito aprovado: a biometria vem do link que a Nio manda depois do crédito.';
    end if;
    v_res := d ->> 'resultado';
    if v_res = 'validada' then
      update public.vendas set biometria_status = 'validada' where id = v.id;
      -- 0191: a mensagem ao cliente sai pela cadência da Mari (cartão: aviso do cadastro do cartão; boleto: confirmação da instalação).
      feito := feito || case when v.forma_pagamento = 'cartao'
                             then 'biometria validada · a Nio manda o link do cartão e a Mari avisa o cliente'
                             else 'biometria validada · a Mari confirma a instalação ao cliente' end::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('remove', jsonb_build_array('biometria-pendente')));
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '✅ Biometria validada — ' || quem || ', ' || agora_t || '. '
            || case when v.forma_pagamento = 'cartao' then 'Cartão: a Nio manda o link do cadastro do cartão; a visita depende dele.'
                    else 'A Mari confirma a instalação ao cliente.' end));
        feito := feito || 'etiqueta'::text || 'nota'::text;
      end if;
    elsif v_res = 'risco' then
      update public.vendas set biometria_status = 'com_risco' where id = v.id;
      feito := feito || 'biometria com risco'::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '⚠️ Biometria com risco — ' || quem || ', ' || agora_t || '. Conferir no portal (só cartão?).'));
        feito := feito || 'nota'::text;
      end if;
    elsif v_res = 'negado' then
      update public.vendas set credito_resultado = 'negado' where id = v.id;
      feito := feito || 'crédito negado'::text;
      if not exists (select 1 from public.venda_pendencias where venda_id = v.id and encerrada_em is null)
         and exists (select 1 from public.config_motivos_pendencia where codigo = 'credito_outro_cpf' and ativo) then
        v_dia := (now() at time zone 'America/Sao_Paulo')::date + 1;
        while extract(isodow from v_dia) = 7 loop v_dia := v_dia + 1; end loop;
        perform public.pendencia_abrir(v.id, 'credito_outro_cpf', null, v_dia);
        feito := feito || 'pendência aberta (outro CPF)'::text;
      end if;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '✕ Crédito negado no CPF do cliente — ' || quem || ', ' || agora_t || '. Pedido outro CPF (pendência aberta).'));
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
        feito := feito || 'nota'::text;
      end if;
    elsif v_res = 'dispensada' then
      -- 0196 (Ricardo, 14/11): com o sistema de biometria fora do ar a Nio libera a venda sem biometria. Vale como aprovada
      -- (comissão normal; no cartão, o link do cadastro do cartão sai logo). O time marca por venda, com motivo e autor.
      if coalesce(btrim(v.nio_os), '') = '' then raise exception 'A dispensa da biometria é depois da OS gravada.'; end if;
      if v.biometria_status = 'validada' then raise exception 'A biometria desta venda já está validada.'; end if;
      update public.vendas set biometria_status = 'validada', biometria_dispensada_em = now(), biometria_dispensada_por = auth.uid(),
             biometria_dispensa_motivo = coalesce(nullif(btrim(d ->> 'motivo'), ''), 'sistema de biometria da Nio fora do ar')
       where id = v.id;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'biometria_dispensada', jsonb_build_object('motivo', coalesce(nullif(btrim(d ->> 'motivo'), ''), 'sistema de biometria da Nio fora do ar'),
              'queda_id', (select q.id from public.biometria_quedas q where q.fim is null order by q.inicio desc limit 1)), auth.uid());
      feito := feito || case when v.forma_pagamento = 'cartao'
                             then 'biometria dispensada pela Nio · a Mari avisa do cadastro do cartão'
                             else 'biometria dispensada pela Nio · a Mari confirma a instalação' end::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('remove', jsonb_build_array('biometria-pendente')));
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🟢 Biometria dispensada pela Nio (sistema de biometria fora do ar) — ' || quem || ', ' || agora_t || '. Vale como aprovada.'));
        feito := feito || 'etiqueta'::text || 'nota'::text;
      end if;
    else
      raise exception 'Biometria: use validada, dispensada, risco ou negado.';
    end if;

  -- ── 0096 (Ricardo, 09/11: "São etapas diferentes"): OS aberta no portal = VENDA (etapa 4). Agendar vem depois. ──
  elsif p_momento = 'os' then
    v_os := btrim(coalesce(d ->> 'os', ''));
    if v_os !~ '^[A-Za-z0-9._/-]{3,40}$' then
      raise exception 'Nº do pedido (OS) inválido: use só letras, números, ponto, barra ou hífen.' using errcode = '22023';
    end if;
    if v.status <> '0_qualificado' then raise exception 'A OS já foi gravada nesta venda.'; end if;
    -- Uma atualização só: se a trava recusar (falta pedido, biometria, viabilidade…), nada fica gravado e a mensagem volta.
    update public.vendas set nio_os = v_os, nio_pedido = v_os, status = '1_vendido' where id = v.id returning * into v;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'os_aberta_portal', jsonb_build_object('os', v_os), auth.uid());
    feito := feito || ('VENDA · pedido (OS) ' || v_os || ' · falta agendar')::text;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 Pedido (OS) nº ' || v_os || ' aberto no portal — VENDA. A Nio manda o link da biometria. Falta gravar a agenda — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
      if coalesce((d ->> 'sem_aviso')::boolean, false) or v.biometria_status = 'validada' then
        feito := feito || 'sem aviso da biometria ao cliente'::text;
      else
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_pedido_biometria', '{}'::jsonb,
                                   'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do link da biometria');
      end if;
    end if;

  -- ── OS + agendamento juntos (0089, mantido para quem já usa) · agendar / reagendar (depois da OS) ──
  elsif p_momento in ('os_agendar', 'agendar') then
    v_dia := nullif(d ->> 'dia', '')::date;
    v_per := coalesce(nullif(d ->> 'periodo', ''), '08:00');
    if v_dia is null then raise exception 'Informe o dia da instalação.'; end if;
    if v_per not in ('08:00', '13:00') then raise exception 'Período inválido.'; end if;
    if v_dia < (now() at time zone 'America/Sao_Paulo')::date then raise exception 'O dia da instalação já passou.'; end if;
    v_ts := (v_dia::text || ' ' || v_per || ':00')::timestamp at time zone 'America/Sao_Paulo';
    v_turno := case when v_per = '13:00' then 'tarde' else 'manha' end;
    if p_momento = 'os_agendar' then
      v_os := btrim(coalesce(d ->> 'os', ''));
      if v_os !~ '^[A-Za-z0-9._/-]{3,40}$' then
        raise exception 'Nº do pedido (OS) inválido: use só letras, números, ponto, barra ou hífen.' using errcode = '22023';
      end if;
      if v.status <> '0_qualificado' then raise exception 'A OS já foi aberta: use Reagendar.'; end if;
      -- 0191 (Ricardo, 14/11): a forma de pagamento escolhida no portal vem junto (pode ter mudado da conversa).
      v_forma := nullif(btrim(coalesce(d ->> 'forma', '')), '');
      if v_forma is not null and v_forma not in ('boleto', 'cartao', 'dacc') then raise exception 'Forma de pagamento inválida.'; end if;
      -- Uma atualização só: se a trava recusar (falta crédito, viabilidade…), nada fica gravado e a mensagem volta.
      update public.vendas set
        nio_os = v_os, nio_pedido = v_os, instalacao_agendada_para = v_ts, instalacao_turno = v_turno,
        forma_pagamento = coalesce(v_forma, forma_pagamento),
        nio_pendencia_cod = null, nio_pendencia_desc = null, status = '2_aguardando_instalacao'
      where id = v.id
      returning * into v;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'os_aberta_portal', jsonb_build_object('os', v_os, 'dia', v_dia, 'turno', v_turno, 'forma', v.forma_pagamento,
              'origem', coalesce(nullif(d ->> 'origem', ''), 'ficha')), auth.uid());
      feito := feito || ('VENDA · OS ' || v_os || ' · instalação ' || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end
                         || ' · a Nio manda o link da biometria')::text;
    else
      if v.status not in ('1_vendido', '2_aguardando_instalacao') then
        raise exception 'Agendar é depois da OS: grave antes o nº do pedido (OS) do portal.';
      end if;
      v_tinha := v.instalacao_agendada_para is not null;
      update public.vendas set
        instalacao_agendada_para = v_ts, instalacao_turno = v_turno, nio_pendencia_cod = null, nio_pendencia_desc = null,
        status = case when status = '1_vendido' then '2_aguardando_instalacao' else status end
      where id = v.id
      returning * into v;
      feito := feito || ('instalação ' || case when v_tinha then 'reagendada ' else 'agendada ' end || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end)::text;
    end if;
    if tem_cw and p_momento = 'os_agendar' then
      -- 0191: OS gravada = a Nio manda o link da biometria. O aviso ao cliente é o da biometria (com a data pré-agendada);
      -- a confirmação da instalação (C2) sai pela cadência depois da biometria aprovada (no cartão, depois do cadastro do cartão).
      v_diatxt := semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM');
      v_pertxt := case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('biometria-pendente', 'instalacao-agendada')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 OS nº ' || v_os || ' aberta — VENDA. Instalação pré-agendada: ' || v_diatxt || ', ' || v_pertxt
          || '. A Nio manda o link da biometria' || case when v.forma_pagamento = 'cartao' then '; depois dela, o link do cadastro do cartão' else '' end
          || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'etiqueta'::text || 'nota'::text;
      if coalesce((d ->> 'sem_aviso')::boolean, false) then
        feito := feito || 'sem aviso ao cliente (o time já avisou)'::text;
      else
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_os_biometria',
                 jsonb_build_object('dia', v_diatxt, 'periodo', v_pertxt),
                 'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso da OS e da biometria');
        if msg ->> 'status' = 'pendente' then
          quando := (msg ->> 'quando')::timestamptz;
          o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'resolver', jsonb_build_object('status', 'resolved'), quando);
          feito := feito || 'conversa resolvida (sem dono)'::text;
        end if;
      end if;
    elsif tem_cw then
      v_diatxt := semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM');
      v_pertxt := case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('instalacao-agendada'), 'remove', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', case when p_momento = 'os_agendar' then '📅 OS nº ' || v_os || ' aberta e instalação agendada: ' when v_tinha then '📅 Instalação reagendada: ' else '📅 Instalação agendada: ' end
          || v_diatxt || ', ' || v_pertxt || ' — ' || quem || ', ' || agora_t || '.'));
      o := o + 1;
      msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_instalacao_confirmada',
               jsonb_build_object('dia', v_diatxt, 'periodo', v_pertxt),
               'nio_instalacao_agendada',
               jsonb_build_array(public.mari_cadencia_nome(c), v_diatxt, v_pertxt,
                 concat_ws(', ', nullif(btrim(v.logradouro), ''), nullif(btrim(v.numero), ''), nullif(btrim(v.complemento), ''), nullif(btrim(v.bairro), ''))),
               'confirmação da instalação');
      feito := feito || 'etiqueta'::text || 'nota'::text;
      if msg ->> 'status' = 'pendente' then
        update public.mari_conversas set instalacao_avisada_para = v_ts, instalacao_avisada_em = (msg ->> 'quando')::timestamptz
         where id = c.id;
        -- 0085: SÓ resolve — a automação 24387 "resolvida → liberar" tira agente e time (a Mari volta se o cliente escrever).
        quando := (msg ->> 'quando')::timestamptz;
        o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'resolver', jsonb_build_object('status', 'resolved'), quando);
        feito := feito || 'conversa resolvida (sem dono)'::text;
      end if;
    end if;

  -- ── cliente pediu para parar ──
  elsif p_momento = 'parar' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    perform public.mari_cadencia_parar(c.id, p_resolvida => true, p_nao_contatar => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente pediu para parar — marcado no NIOGEN por ' || quem || ']', false);
    feito := feito || 'não contatar'::text;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('nao-contatar')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🚫 Cliente pediu para parar — ' || quem || ', ' || agora_t || '. Nunca mais chamar.'));
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'resolver', jsonb_build_object('status', 'resolved'));
      feito := feito || 'etiqueta'::text || 'nota'::text || 'conversa resolvida'::text;
    end if;

  -- ── devolver para a Mari ──
  elsif p_momento = 'devolver_mari' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
    -- 0155: em handoff a Mari fica calada; devolver fecha o ciclo (status ativo, etapa retomada) sem marcar "resolvida"
    if c.status = 'handoff_realizado' then
      perform public._mari_fechar_ciclo(c.id, 'devolvida para a Mari no NIOGEN por ' || quem);
    end if;
    update public.mari_conversas set chatwoot_resolvida = false where id = c.id and coalesce(funil_destino, 'em_andamento') = 'em_andamento';
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[devolvida para a Mari no NIOGEN por ' || quem || ']', false);
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '↩ Devolvida para a Mari por ' || quem || ' às ' || agora_t || ' — a Mari continua.'));
      feito := feito || 'atribuição removida'::text || 'nota'::text;
    end if;
  end if;

  if msg is not null then
    if msg ->> 'status' = 'pendente' then
      quando := (msg ->> 'quando')::timestamptz;
      feito := feito || ('mensagem ao cliente' || case when quando > now() + interval '2 minutes'
                then ' — sai ' || case when (quando at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date
                                       then 'às ' else to_char(quando at time zone 'America/Sao_Paulo', 'DD/MM') || ' às ' end
                     || to_char(quando at time zone 'America/Sao_Paulo', 'HH24:MI') else '' end
                || case when msg ->> 'template' is not null then ' (template ' || (msg ->> 'template') || ')' else '' end)::text;
    else
      aviso := concat_ws(' ', aviso, 'A mensagem ao cliente NÃO saiu (' || (msg ->> 'motivo') || '): mande à mão pelo Chatwoot — está no Live.');
    end if;
  end if;
  if c.id is not null and not tem_cw and c.telefone like '5500000000%' then
    aviso := concat_ws(' ', aviso, 'Telefone de teste: nada foi ao Chatwoot.');
  elsif c.id is null and p_momento in ('pedido', 'os', 'os_agendar', 'agendar', 'biometria') then
    aviso := concat_ws(' ', aviso, 'Venda sem conversa no Chatwoot: avise o cliente por ligação.');
  end if;

  r := jsonb_strip_nulls(jsonb_build_object('ok', true, 'momento', p_momento, 'grupo', g, 'acoes', o,
         'feito', to_jsonb(feito), 'resumo', '✓ ' || array_to_string(feito, ', '), 'aviso', aviso,
         'mensagem', msg - 'texto', 'venda_id', v.id, 'conversa_id', c.id));
  if v.id is not null then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'backoffice', jsonb_strip_nulls(jsonb_build_object('momento', p_momento, 'resumo', r ->> 'resumo', 'aviso', aviso,
            'mensagem', msg ->> 'status', 'resultado', d ->> 'resultado')), auth.uid());
  end if;
  return r;
end;
$function$;

CREATE OR REPLACE FUNCTION public.mari_cadencia_avaliar(p_agora timestamp with time zone DEFAULT now(), p_conversa uuid DEFAULT NULL::uuid)
 RETURNS TABLE(conversa_id uuid, telefone text, canal text, chatwoot_conversation_id text, status text, etapa text, passo_atual text, passo_em timestamp with time zone, proximo_passo text, proximo_em timestamp with time zone, pode_enviar boolean, bloqueio text, acao text, template text, categoria text, params jsonb, texto text, excecao text, janela_aberta boolean, janela_fecha_em timestamp with time zone, toques_hoje integer, toques_mes integer, ligar_sugerido boolean, venda_id uuid)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  v_tq     record;
  v_teto   record;   -- 0102: config_regras.contato_teto_dia/_mes (nulo = sem teto)
  L        timestamptz;   -- última msg do lead
  M        timestamptz;   -- última msg da Mari
  B        timestamptz;   -- base dos D (lead, retorno ou 1º contato)
  f1_at    timestamptz; f_base timestamptz; f_ant timestamptz; fats timestamptz[]; fval timestamptz[]; k int; k2 int; f2_at timestamptz; f2_ate timestamptz; a_ant timestamptz;
  d3_at    timestamptz; d7_at timestamptz; d15_at timestamptz; enc_at timestamptz;
  seq      text[]; ats timestamptz[]; validos timestamptz[];
  idx_atual int; i int; alvo int; prox int;
  v_passo  text; v_at timestamptz; v_bloq text; v_acao text; v_tpl text; v_cat text; v_params jsonb; v_txt text;
  v_exc    text; v_pode boolean; v_janela boolean; v_lig boolean;
  v_venda  record; vis_dia date; vis_ini timestamptz; v_proib text;
  v_turno  text; v_dia date;
  v_inst   boolean;
  v_volta  timestamptz;   -- 0196   -- 0114: venda com instalação agendada (aviso/lembrete são da venda, não da conversa)
  l15_at   timestamptz; v_ab_em timestamptz; v_ab_tags jsonb;   -- 0070: lembrete leve da abertura B2
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
begin
  select * into v_teto from public.contato_teto();
  for c in
    select * from public.mari_conversas mc
     where (p_conversa is null or mc.id = p_conversa)
       and mc.canal in ('teste', 'whatsapp')
       and (mc.status = 'ativo'
            or (mc.status = 'handoff_realizado' and mc.venda_id is not null))   -- biometria pendente / instalação agendada
     order by mc.updated_at desc
  loop
    v_passo := null; v_at := null; v_bloq := null; v_acao := null; v_tpl := null; v_cat := null;
    v_params := null; v_txt := null; v_exc := null; v_pode := false; v_lig := false;
    L := c.ultima_msg_lead_at; M := c.ultima_msg_mari_at;
    v_janela := L is not null and p_agora < L + interval '23 hours';
    select * into v_tq from public.mari_toques(c.telefone, p_agora);
    -- ── paradas absolutas ──
    if c.nao_contatar then v_bloq := 'cliente pediu para não ser contatado';
    elsif c.humano_atribuido then v_bloq := 'humano atribuído no Chatwoot';
    elsif c.time_atribuido then v_bloq := 'time atribuído no Chatwoot';
    elsif c.chatwoot_resolvida then v_bloq := 'conversa resolvida no Chatwoot';
    elsif c.canal = 'whatsapp' and c.telefone like '5500000000%' then v_bloq := 'telefone de teste';
    -- 0064 (08/11): venda "Em espera" (pendência com terceiro aberta) pausa toda a cadência até a pendência ser encerrada.
    elsif c.venda_id is not null and exists (select 1 from public.venda_pendencias vp
                                              where vp.venda_id = c.venda_id and vp.encerrada_em is null) then
      v_bloq := 'venda em espera (pendência com terceiro)';
    end if;
    -- 0114 (Ricardo, 10/11 ~20h40 "Sim, faça os dois"): o aviso do agendamento (C2) e o lembrete da véspera (C3) são da VENDA —
    -- saem com a conversa em qualquer estado (ativa ou em handoff), com humano/time atribuído, resolvida no Chatwoot ou com
    -- pendência aberta. Só "não contatar" e telefone de teste param.
    v_inst := c.venda_id is not null and exists (select 1 from public.vendas vi where vi.id = c.venda_id
                and vi.status = '2_aguardando_instalacao' and vi.instalacao_agendada_para > p_agora);
    if v_inst and not coalesce(c.nao_contatar, false) and not (c.canal = 'whatsapp' and c.telefone like '5500000000%') then
      v_bloq := null;
    end if;
    if c.status = 'handoff_realizado' or v_inst then
      -- ── venda remota (05/11): biometria pendente e instalação agendada ──
      if v_bloq is not null then continue; end if;
      select v.id, v.status, v.biometria_status, v.biometria_link, v.biometria_link_enviado_em, v.forma_pagamento, v.biometria_validada_em,
             exists (select 1 from public.os_andamento oa where oa.venda_id = v.id and oa.estado is not null
                       and oa.estado <> 'aguardando_pagamento' and oa.mudou_em > v.biometria_validada_em) as cartao_ok,
             v.instalacao_agendada_para, v.instalacao_turno, v.logradouro, v.numero, v.complemento, v.bairro
        into v_venda
        from public.vendas v
       where v.id = c.venda_id and v.status <> 'saida';
      if not found then continue; end if;
      -- 0191: a biometria vem DEPOIS da OS — os lembretes valem também com a venda já contada (Ativação/Agenda).
      if v_venda.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao') and v_venda.biometria_status = 'pendente' and v_venda.biometria_link_enviado_em is not null then
        select q.fim into v_volta from public.biometria_quedas q
         where q.fim is not null and q.fim > p_agora - interval '48 hours' and q.inicio > v_venda.biometria_link_enviado_em - interval '15 days'
           and v_venda.biometria_link_enviado_em < q.fim
         order by q.fim desc limit 1;
        if v_volta is not null and (c.bio_volta_em is null or c.bio_volta_em < v_volta) then
          -- 0196: a biometria da Nio voltou depois de uma queda e este cliente ficou esperando: a Mari avisa (só na janela de 24 h).
          v_passo := 'BIOVOLTA'; v_at := v_volta;
          select replace(t.texto, '{nome}', public.mari_cadencia_nome(c)) into v_txt from public.config_mari_textos t where t.chave = 'mari_bio_voltou';
          v_acao := 'texto'; v_tpl := null;
          if not v_janela then v_bloq := 'janela de 24 h fechada: o time fala com o cliente (Live)'; end if;
        elsif c.bio_lembrete_em is null or c.bio_lembrete_em < v_venda.biometria_link_enviado_em then
          -- BIO1: D+1 do link, uma vez só. 0032: o link é da Nio (WhatsApp + e-mail, na hora do pedido) — a contagem parte
          -- da hora do pedido e o lembrete é o C1 v2 (sem botão de link): lembra que a Nio mandou, conferir o spam, ajuda por aqui.
          v_passo := 'BIO1';
          v_at := public.mari_proximo_horario(v_venda.biometria_link_enviado_em + interval '1 day', c.cidade);
          v_tpl := 'nio_lembrete_biometria_v2';
          v_params := jsonb_build_array(public.mari_cadencia_nome(c));
          v_txt := public.mari_render_template(v_tpl, v_params);
          if v_janela then
            v_acao := 'texto'; v_tpl := null;   -- texto livre (janela de 24 h): o mesmo texto do C1 v2
          else
            v_acao := 'template'; v_cat := 'UTILITY';
          end if;
          if p_agora < v_at then v_bloq := 'aguardando o D+1 do link da biometria (hora do pedido)';
          end if;
        else
          -- BIO3: D+3 sem biometria → o humano liga. Nunca automático.
          v_passo := 'BIO3'; v_acao := 'ligar';
          v_at := v_venda.biometria_link_enviado_em + interval '3 days';
          v_lig := p_agora >= v_at;
          v_bloq := case when p_agora < v_at then 'aguardando o D+3 do link da biometria (hora do pedido)'
                         else 'D+3 sem biometria: o nosso time liga para o cliente (nunca automático)' end;
        end if;
      elsif v_venda.status = '2_aguardando_instalacao' and v_venda.instalacao_agendada_para > p_agora
            and v_venda.biometria_status = 'validada' then   -- 0191: confirmação da instalação só depois da biometria aprovada
        v_dia := (v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date;
        v_turno := coalesce(v_venda.instalacao_turno,
                            case when extract(hour from v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo') >= 12
                                 then 'tarde' else 'manha' end);
        if v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok and c.cartao_avisado_em is null then
          -- 0191 (Ricardo, 14/11): cartão — biometria aprovada, a Nio manda o link do cadastro do cartão. A Mari avisa com jeitinho.
          v_passo := 'CARTAO'; v_at := p_agora;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end);
          select replace(replace(replace(t.texto, '{nome}', v_params ->> 0), '{dia}', v_params ->> 1), '{periodo}', v_params ->> 2)
            into v_txt from public.config_mari_textos t where t.chave = 'mari_cartao_aviso';
          if v_janela then v_acao := 'texto'; v_tpl := null;
          else v_acao := 'template'; v_tpl := 'nio_cartao_cadastro'; v_cat := 'UTILITY'; end if;
        elsif v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok and c.cartao_lembrete_em is null then
          -- 0191: 24 h sem o cadastro do cartão → um lembrete gentil. 48 h → o time liga (v_jornada / Live).
          v_passo := 'CARTAO2';
          v_at := public.mari_proximo_horario(c.cartao_avisado_em + interval '24 hours', c.cidade);
          v_params := jsonb_build_array(public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end);
          select replace(replace(replace(t.texto, '{nome}', v_params ->> 0), '{dia}', v_params ->> 1), '{periodo}', v_params ->> 2)
            into v_txt from public.config_mari_textos t where t.chave = 'mari_cartao_lembrete';
          if v_janela then v_acao := 'texto'; v_tpl := null;
          else v_acao := 'template'; v_tpl := 'nio_cartao_cadastro'; v_cat := 'UTILITY'; end if;
          if p_agora < v_at then v_bloq := 'aguardando 24 h do aviso do cartão'; end if;
        elsif v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok then
          continue;   -- 0191: lembrete já saiu; esperando o cadastro do cartão (48 h → o time liga)
        elsif c.instalacao_avisada_para is distinct from v_venda.instalacao_agendada_para then
          -- C2: assim que agendar (ou reagendar).
          v_passo := 'INSTALACAO'; v_at := p_agora;
          v_params := jsonb_build_array(
            public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end,
            concat_ws(', ', nullif(btrim(v_venda.logradouro), ''), nullif(btrim(v_venda.numero), ''),
                      nullif(btrim(v_venda.complemento), ''), nullif(btrim(v_venda.bairro), '')));
          v_tpl := 'nio_instalacao_agendada';
        elsif c.instalacao_lembrada_para is distinct from v_venda.instalacao_agendada_para then
          -- C3: véspera (dia permitido anterior).
          vis_dia := v_dia - 1;
          while not public.mari_dia_permitido(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          vis_ini := public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade);
          v_passo := 'VESPERA'; v_at := vis_ini;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), to_char(v_dia, 'DD/MM'),
                                        case v_turno when 'tarde' then 'tarde' else 'manhã' end);
          v_tpl := 'nio_lembrete_instalacao';
          if p_agora < v_at then v_bloq := 'aguardando a véspera da instalação';
          -- 0114: o texto diz "é amanhã" — nunca sai no próprio dia da instalação.
          elsif (p_agora at time zone 'America/Sao_Paulo')::date >= v_dia then v_bloq := 'a véspera passou (o lembrete diz "amanhã")';
          elsif p_agora > v_venda.instalacao_agendada_para - interval '2 hours' then v_bloq := 'instalação próxima demais';
          elsif c.instalacao_avisada_em > p_agora - interval '12 hours' then v_bloq := 'o aviso do agendamento (C2) saiu há menos de 12 h';
          end if;
        else
          continue;
        end if;
        if v_passo in ('INSTALACAO', 'VESPERA') then
        v_txt := public.mari_render_template(v_tpl, v_params);
        -- 0114: aviso e lembrete da instalação saem SEMPRE como template (com os botões Confirmo/Tudo certo · Preciso remarcar),
        -- mesmo com a janela aberta — a resposta ao botão é o que preenche "Confirmou?" (0112).
        v_acao := 'template'; v_cat := 'UTILITY';
        end if;
      else
        continue;   -- nada a fazer nesta conversa em handoff
      end if;
    elsif v_bloq is null and c.status = 'ativo' then
      -- 0050 (Ricardo, 06/11): venda em Saída não recebe nada da cadência ("Interesse futuro" vira etiqueta no
      -- Chatwoot, 0052; "Sem cobertura" não ganha nada).
      if c.venda_id is not null and exists (select 1 from public.vendas vs where vs.id = c.venda_id and vs.status = 'saida') then
        continue;
      end if;
      -- ── retorno pedido pelo cliente: prioridade, pode sair fora do horário ──
      if c.agendamento_retorno is not null
         and c.agendamento_retorno > coalesce(L, c.created_at)
         and (c.cadencia_retorno_em is null or c.cadencia_retorno_em < c.agendamento_retorno) then
        v_passo := 'RETORNO'; v_at := c.agendamento_retorno; v_exc := 'pedido do cliente';
        if v_janela then
          v_acao := 'texto';
          v_txt := 'Oi' || case when public.mari_cadencia_nome(c) <> 'tudo bem' then ', ' || public.mari_cadencia_nome(c) else '' end
                   || '! Como combinamos, estou passando pra gente retomar. Quer seguir de onde paramos? 😊';
        else
          v_acao := 'template'; v_tpl := 'nio_retomada_lead_d3'; v_cat := 'MARKETING';
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), public.mari_cadencia_contexto(c));
          v_txt := public.mari_render_template(v_tpl, v_params);
        end if;
        if p_agora < v_at then v_bloq := 'retorno agendado pelo cliente'; end if;
      elsif c.processando_ate is not null and c.processando_ate > p_agora then
        v_bloq := 'Mari respondendo agora';
      elsif L is null and c.origem not in ('meta_ads', 'site', 'indicacao') then
        continue;   -- sem mensagem do lead e sem origem de formulário: não há escada
      elsif L is not null and (M is null or M < L) and c.cadencia_passo = 'nenhum' then
        v_bloq := 'aguardando a Mari responder';
      else
        -- ── a escada ──
        B := greatest(coalesce(L, '-infinity'::timestamptz), coalesce(c.cadencia_retorno_em, '-infinity'::timestamptz));
        if L is null then
          B := coalesce((select min(cc.em) from public.contatos_cliente cc where cc.conversa_id = c.id and cc.toque = 'P1'),
                        c.cadencia_passo_em, c.created_at);
          seq := array['P1', 'D7', 'D15', 'ENCERRAR'];
          ats := array[c.created_at, B + interval '7 days', B + interval '15 days', null];
          validos := array[B + interval '7 days', B + interval '15 days', 'infinity'::timestamptz, 'infinity'::timestamptz];
        else
          -- 0141 (Ricardo, 12/11): 5 cutucadas na janela de 24 h, em QUALQUER etapa: 15 min, 1 h, 3 h e 6 h depois da última fala
          -- REAL da Mari e a última chamada ~20 h depois da mensagem do cliente. Fora do horário do contrato (seg–sex 9–21, sáb
          -- 10–16, nunca domingo/feriado) vai para a abertura seguinte, com no mínimo 45 min entre duas, se ainda couber na janela
          -- (até L + 23 h); senão é pulada. O cliente respondeu → L muda e a escada recomeça. Substitui L15/F1/F2.
          f_base := coalesce((select max(t.created_at) from public.mari_turnos t
                               where t.conversa_id = c.id and t.papel = 'mari' and coalesce(t.tags ->> 'cadencia', '') = ''), M);
          fats := array[f_base + interval '15 minutes', f_base + interval '1 hour', f_base + interval '3 hours',
                        f_base + interval '6 hours', L + interval '20 hours'];
          f_ant := null;
          for k in 1..5 loop
            if c.cadencia_retorno_em is not null then fats[k] := null; continue; end if;
            if f_ant is not null and fats[k] < f_ant + interval '45 minutes' then fats[k] := f_ant + interval '45 minutes'; end if;
            if not public.mari_no_horario(fats[k], c.cidade) then fats[k] := public.mari_proximo_horario(fats[k], c.cidade); end if;
            if fats[k] is null or fats[k] >= L + interval '23 hours' then fats[k] := null; else f_ant := fats[k]; end if;
          end loop;
          fval := array[null, null, null, null, null]::timestamptz[];
          for k in 1..5 loop
            fval[k] := L + interval '23 hours';
            if k < 5 then
              for k2 in (k + 1)..5 loop
                if fats[k2] is not null then fval[k] := least(fats[k2], fval[k]); exit; end if;
              end loop;
            end if;
          end loop;
          d3_at := B + interval '3 days'; d7_at := B + interval '7 days'; d15_at := B + interval '15 days';
          seq := array['F1', 'F2', 'F3', 'F4', 'F5', 'D3', 'D7', 'D15', 'ENCERRAR'];
          ats := array[fats[1], fats[2], fats[3], fats[4], fats[5], d3_at, d7_at, d15_at, null];
          validos := array[fval[1], fval[2], fval[3], fval[4], fval[5], d7_at, d15_at,
                           'infinity'::timestamptz, 'infinity'::timestamptz];
        end if;
        if c.cadencia_passo = 'D15' then
          ats[array_length(seq, 1)] := c.cadencia_passo_em + interval '48 hours';
        end if;
        idx_atual := coalesce(array_position(seq, c.cadencia_passo), 0);
        if c.cadencia_passo = 'F2' and seq[1] = 'P1' then idx_atual := 1; end if;
        alvo := null; prox := null;
        for i in (idx_atual + 1)..array_length(seq, 1) loop
          if ats[i] is null then continue; end if;
          if seq[i] in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') and ats[i] <= p_agora and not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
          if ats[i] <= p_agora and p_agora < validos[i] then alvo := i;
          elsif ats[i] > p_agora and prox is null then prox := i;
          end if;
        end loop;
        if alvo is not null then
          v_passo := seq[alvo]; v_at := ats[alvo];
        elsif prox is not null then
          v_passo := seq[prox]; v_at := ats[prox]; v_bloq := 'aguardando';
        else
          continue;
        end if;
        if v_passo in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') then
          v_acao := 'texto'; v_txt := public.mari_cadencia_texto(c, v_passo);
        elsif v_passo = 'ENCERRAR' then
          v_acao := 'encerrar'; v_txt := null;
        else
          v_acao := 'template';
          v_tpl := case v_passo when 'P1' then 'nio_primeiro_contato' when 'D3' then 'nio_retomada_lead_d3'
                                when 'D7' then 'nio_retomada_lead_d7' else 'nio_retomada_lead_d15' end;
          v_cat := 'MARKETING';
          v_params := case when v_tpl = 'nio_retomada_lead_d3'
                           then jsonb_build_array(public.mari_cadencia_nome(c), public.mari_cadencia_contexto(c))
                           else jsonb_build_array(public.mari_cadencia_nome(c)) end;
          v_txt := public.mari_render_template(v_tpl, v_params);
        end if;
        if v_passo in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') and not v_janela then v_bloq := 'janela de 24 h fechada'; end if;
        -- 0050 (Ricardo, 06/11): venda já criada NUNCA sai sozinha e não recebe a escada de templates de lead —
        -- só as cutucadas F1/F2 dentro da janela; o resto é do backoffice, pela venda.
        if c.venda_id is not null and v_passo not in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') then
          v_bloq := 'venda criada: o backoffice segue pela venda (a cadência não manda D3/D7/D15 nem encerra)';
        end if;
        v_lig := c.cadencia_passo = 'D3' and p_agora >= c.cadencia_passo_em + interval '1 day' and p_agora < B + interval '6 days';
      end if;
    end if;
    if v_passo is null then
      if v_bloq is null then continue; end if;
    end if;
    -- 0110 (Ricardo, 10/11 16h02): o time mandou (ou ligou) pela 🔥 oportunidade HOJE e o cliente ainda não respondeu →
    -- nenhum toque automático no mesmo dia (nunca dois toques num dia: um do humano e um da Mari); o próximo vai para o dia
    -- útil seguinte. Retorno pedido pelo cliente (v_exc) segue valendo. Cliente respondeu → L passa da mensagem e a regra é a de sempre.
    if v_bloq is null and v_passo is not null and v_exc is null and v_acao in ('texto', 'template')
       and v_passo not in ('INSTALACAO', 'VESPERA', 'CARTAO', 'CARTAO2', 'BIOVOLTA')   -- 0114: aviso/lembrete da instalação não são toque de venda
       and exists (select 1 from public.oportunidades_log ol
                    where ol.conversa_id = c.id and ol.tipo = 'enviada'
                      and ol.criado_em > coalesce(L, '-infinity'::timestamptz)
                      and (ol.criado_em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date) then
      v_bloq := 'o time falou com o cliente hoje (🔥 oportunidade): o toque vai para o próximo dia útil';
      v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
    end if;
    -- ── regras duras do envio: horário, teto, filtro de texto ──
    if v_bloq is null and v_acao not in ('encerrar', 'ligar') then
      if v_exc is null and not public.mari_no_horario(p_agora, c.cidade) then
        v_bloq := 'fora do horário';
        v_at := greatest(v_at, public.mari_proximo_horario(p_agora, c.cidade));
      elsif v_teto.dia is not null and v_tq.hoje >= v_teto.dia then
        v_bloq := 'limite do dia (' || v_teto.dia || ' toques)';
        v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
      elsif v_teto.mes is not null and v_tq.mes >= v_teto.mes then
        v_bloq := 'limite do mês (' || v_teto.mes || ' toques)';
      elsif v_acao = 'template' and not exists (select 1 from public.config_templates_waba t where t.nome = v_tpl and t.status = 'APPROVED') then
        v_bloq := 'template não aprovado';
      else
        v_proib := public.mari_texto_proibido(v_txt);
        if v_proib is not null then v_bloq := 'texto reprovado no filtro (' || v_proib || ')'; end if;
      end if;
    end if;
    v_pode := v_passo is not null and v_bloq is null and v_acao is distinct from 'ligar';
    conversa_id := c.id; telefone := c.telefone; canal := c.canal; chatwoot_conversation_id := c.chatwoot_conversation_id;
    status := c.status; etapa := c.etapa; passo_atual := c.cadencia_passo; passo_em := c.cadencia_passo_em;
    proximo_passo := v_passo; proximo_em := v_at; pode_enviar := v_pode; bloqueio := v_bloq; acao := v_acao;
    template := v_tpl; categoria := v_cat; params := v_params; texto := v_txt; excecao := v_exc;
    janela_aberta := v_janela; janela_fecha_em := case when L is not null then L + interval '24 hours' end;
    toques_hoje := v_tq.hoje; toques_mes := v_tq.mes; ligar_sugerido := v_lig; venda_id := c.venda_id;
    return next;
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.mari_cadencia_registrar(p_conversa uuid, p_passo text, p_ok boolean, p_erro text DEFAULT NULL::text, p_agora timestamp with time zone DEFAULT now(), p_texto text DEFAULT NULL::text, p_excecao text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  c public.mari_conversas;
  v_bio timestamptz;
  v_inst timestamptz;
  v_prox record;
  v_eco int := 0;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'conversa inexistente'); end if;

  if not coalesce(p_ok, false) then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, 'mari_cadencia', 'envio da cadência falhou (' || coalesce(p_passo, '?') || '): ' || coalesce(p_erro, 'sem detalhe'),
            jsonb_build_object('passo', p_passo, 'agora', p_agora));
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;

  if p_passo = 'ENCERRAR' then
    update public.mari_conversas set status = 'encerrado_ia', handoff_motivo = 'sem_contato',
           cadencia_passo = 'encerrada', cadencia_passo_em = p_agora, cadencia_proximo_em = null
     where id = p_conversa;
    insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
    values (p_conversa, 'sistema', 'Saída "Sem contato": 48 h sem resposta depois do D15.',
            jsonb_build_object('cadencia', 'ENCERRAR'), p_agora);
    return jsonb_build_object('ok', true, 'registrado', 'encerrada');
  end if;
  if p_passo = 'BIO3' then
    return jsonb_build_object('ok', false, 'erro', 'BIO3 é ligação do nosso time: nunca registrada como envio automático');
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
  values (p_conversa, 'mari', coalesce(p_texto, ''),
          jsonb_strip_nulls(jsonb_build_object('cadencia', p_passo, 'excecao', p_excecao, 'simulado', c.canal = 'teste')), p_agora);

  -- 0052: eco do próprio envio que chegou ao mari_principal ANTES deste registro (virou turno 'humano' falso).
  if c.canal = 'whatsapp' and coalesce(btrim(p_texto), '') <> '' then
    delete from public.mari_turnos t
     where t.conversa_id = p_conversa and t.papel = 'humano'
       and btrim(t.texto) = btrim(p_texto)
       and t.created_at >= p_agora - interval '1 minute'
       and t.created_at <= greatest(now(), p_agora) + interval '5 minutes';
    get diagnostics v_eco = row_count;
  end if;

  insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
  values (c.venda_id, c.id, c.telefone, 'whatsapp', 'saida', 'mari', p_agora, p_passo, 'ativo',
          'cadência ' || p_passo || coalesce(' · ' || p_excecao, '') || case when c.canal = 'teste' then ' (simulado)' else '' end);

  if p_passo = 'RETORNO' then
    update public.mari_conversas set cadencia_retorno_em = p_agora,
           cadencia_passo = case when cadencia_passo in ('nenhum', 'L15', 'F1', 'F2', 'F3', 'F4', 'P1') then 'F5' else cadencia_passo end,
           cadencia_passo_em = p_agora
     where id = p_conversa;
  elsif p_passo = 'VISITA' then   -- histórico (0018); não é mais gerado
    select biometria_em into v_bio from public.vendas where id = c.venda_id;
    update public.mari_conversas set visita_confirmada_para = v_bio where id = p_conversa;
  elsif p_passo = 'BIO1' then
    update public.mari_conversas set bio_lembrete_em = p_agora where id = p_conversa;
  elsif p_passo = 'BIOVOLTA' then   -- 0196
    update public.mari_conversas set bio_volta_em = p_agora where id = p_conversa;
  elsif p_passo = 'CARTAO' then   -- 0191
    update public.mari_conversas set cartao_avisado_em = p_agora where id = p_conversa;
  elsif p_passo = 'CARTAO2' then
    update public.mari_conversas set cartao_lembrete_em = p_agora where id = p_conversa;
  elsif p_passo = 'INSTALACAO' then
    select instalacao_agendada_para into v_inst from public.vendas where id = c.venda_id;
    update public.mari_conversas set instalacao_avisada_para = v_inst, instalacao_avisada_em = p_agora where id = p_conversa;
  elsif p_passo = 'VESPERA' then
    select instalacao_agendada_para into v_inst from public.vendas where id = c.venda_id;
    update public.mari_conversas set instalacao_lembrada_para = v_inst where id = p_conversa;
  elsif p_passo = 'L15' then   -- 0070: lembrete da abertura B2 — passo + horário em dados (medição v_mari_abertura)
    update public.mari_conversas set cadencia_passo = p_passo, cadencia_passo_em = p_agora,
           dados = dados || jsonb_build_object('abertura_lembrete_em', p_agora)
     where id = p_conversa;
  else
    update public.mari_conversas set cadencia_passo = p_passo, cadencia_passo_em = p_agora where id = p_conversa;
  end if;

  select a.proximo_passo, a.proximo_em into v_prox
    from public.mari_cadencia_avaliar(p_agora + interval '1 second', p_conversa) a limit 1;
  update public.mari_conversas set cadencia_proximo_em = v_prox.proximo_em where id = p_conversa;

  return jsonb_build_object('ok', true, 'registrado', p_passo, 'proximo_passo', v_prox.proximo_passo,
                            'proximo_em', v_prox.proximo_em, 'eco_removido', v_eco);
end;
$function$;

CREATE OR REPLACE FUNCTION public.mari_cadencia_candidatos(p_agora timestamp with time zone DEFAULT now(), p_canal text DEFAULT 'teste'::text, p_limite integer DEFAULT 30)
 RETURNS SETOF jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select to_jsonb(a) from public.mari_cadencia_avaliar(p_agora, null) a
   where a.pode_enviar and a.canal = p_canal
   order by case a.proximo_passo when 'RETORNO' then 0 when 'INSTALACAO' then 1 when 'VESPERA' then 1 when 'BIO1' then 1 when 'CARTAO' then 1 when 'BIOVOLTA' then 1 when 'CARTAO2' then 1
                                 when 'F1' then 2 when 'F2' then 3 when 'F3' then 3 when 'F4' then 3 when 'F5' then 3 else 4 end,
            a.proximo_em
   limit least(greatest(coalesce(p_limite, 30), 1), 30)
$function$;

CREATE OR REPLACE FUNCTION public.live_conferir()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_horas numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'envelhecimento_dono_horas'), 24);
  v_docs  int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return '[]'::jsonb; end if;
  with nomes as (
    select c.id, c.venda_id,
           coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
           c.chatwoot_agente, c.funil_alerta, c.funil_alerta_em, coalesce(c.nao_contatar, false) as nao_contatar
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
  ),
  itens as (
    -- (a) ação do Chatwoot que falhou 3 vezes e não foi refeita depois
    select 'acao_falhou' as tipo, a.id::text as chave, a.conversa_id, a.venda_id, n.nome, a.criada_em as desde, 1 as ordem,
           format('O Chatwoot não obedeceu: %s%s', case a.tipo when 'resolver' then 'resolver / reabrir' when 'etiquetas' then 'etiqueta'
                    when 'atribuir' then 'atribuir' when 'desatribuir' then 'tirar a atribuição' when 'nota' then 'nota privada'
                    when 'mensagem' then 'mensagem ao cliente' else a.tipo end,
                  coalesce(' — ' || left(a.erro, 120), '')) as texto
      from public.chatwoot_acoes a
      left join nomes n on n.id = a.conversa_id
     where a.status = 'erro' and a.criada_em > now() - interval '7 days'
       and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                         and b.status = 'feita' and b.criada_em > a.criada_em)
    union all
    -- (b) conversa mexida direto no Chatwoot
    select 'fora_niogen', n.id::text, n.id, n.venda_id, n.nome, n.funil_alerta_em, 2,
           case n.funil_alerta
             when 'resolvida_fora_niogen' then 'Resolvida direto no Chatwoot, sem destino — registre a Saída (ou reabra)'
             when 'mensagem_fora_niogen' then case when n.nao_contatar   -- 0183
               then 'O time respondeu direto no Chatwoot a quem pediu para NÃO ser contatado — não escrever de novo; abrir a conversa no NIOGEN e conferir'
               else 'Respondida direto no Chatwoot — responda pelo NIOGEN para a venda andar' end
             when 'atribuida_fora_niogen' then 'Atribuída direto no Chatwoot a ' || coalesce(n.chatwoot_agente, 'alguém') || ' — a Mari calou; assuma pelo NIOGEN ou devolva para a Mari'
             else 'Adiada direto no Chatwoot — some da fila sem data de volta; use ⏸ Aguardar no NIOGEN' end
      from nomes n where n.funil_alerta is not null
    union all
    -- (c) conversa em andamento com dono e sem nenhuma fala há mais de N horas
    select case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then 'handoff_parado' else 'dono_parado' end,
           c.id::text, c.id, c.venda_id, n.nome, u.ult, 3,
           format(case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido
                       then 'Passada pela Mari%s e ninguém pegou há %s — assumir, devolver para a Mari ou registrar a Saída'
                       else 'Com %s e parada há %s — retomar, devolver para a Mari ou registrar a Saída' end,
                  case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then ''
                       else coalesce(c.chatwoot_agente, 'o time') end,
                  case when now() - u.ult >= interval '48 hours' then floor(extract(epoch from now() - u.ult) / 86400)::int || ' dias'
                       else floor(extract(epoch from now() - u.ult) / 3600)::int || ' h' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
      left join public.vendas v on v.id = c.venda_id
      cross join lateral (select max(t.created_at) as ult from public.mari_turnos t
                           where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')) u
     where coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status = 'handoff_realizado')   -- 0155
       and not coalesce(c.nao_contatar, false)
       and c.quadro_encerrada_motivo is null
       and (c.espera_ate is null or c.espera_ate <= now())
       and coalesce(c.chatwoot_status, 'open') <> 'snoozed'
       and (v.id is null or v.status in ('0_qualificado', '1_vendido'))
       and not exists (select 1 from public.venda_pendencias vp where vp.venda_id = c.venda_id and vp.encerrada_em is null)
       and u.ult is not null and u.ult < now() - make_interval(mins => (v_horas * 60)::int)
    union all
    -- (d) documentos à Nio: 15 dias depois da instalação
    select 'docs_prazo', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), v.instalado_em, 4,
           case when v.instalado_em + make_interval(days => v_docs) < now()
                  then format('Documentos à Nio ATRASADOS — o prazo era %s', to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'))
                else format('Documentos à Nio até %s (%s dias depois da instalação)',
                            to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'), v_docs) end
      from public.vendas v
     where v.status in ('3_instalado', '4_ativo_provisorio') and v.instalado_em is not null and v.docs_entregues_em is null
       and v.instalado_em > now() - interval '90 days'
    union all
    -- (e) 0155: cliente já instalado escreveu e ninguém do time respondeu — pós-venda
    select 'pos_venda', c.id::text, c.id, c.venda_id, n.nome, u.ult_lead, 2,
           'Cliente já instalado escreveu — é pós-venda: responda você (a Mari não responde cliente instalado)'
      from public.mari_conversas c
      join nomes n on n.id = c.id
      cross join lateral (select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
                                 max(t.created_at) filter (where t.papel = 'humano') as ult_hum
                            from public.mari_turnos t where t.conversa_id = c.id) u
     where c.funil_destino = 'instalada' and u.ult_lead is not null and u.ult_lead > now() - interval '14 days'
       and u.ult_lead > coalesce(u.ult_hum, '-infinity') and u.ult_lead > coalesce(c.dispensada_em, '-infinity')
    union all
    -- (f) 0157: saiu com pedido ou OS aberta na Nio e ninguém confirmou o cancelamento no portal
    select 'cancelar_nio', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), ev.em, 2,
           'Saiu com pedido aberto na Nio' || coalesce(' (nº ' || coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) || ')', '')
             || ' — cancele no portal e confirme aqui. Pedido vivo trava o CPF e o endereço (recompra = multa de R$ 500)'
      from public.vendas v
      cross join lateral (select max(e.criado_em) as em from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'status') ev
     where v.status = 'saida' and v.instalado_em is null
       and (nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null)
       and coalesce(v.motivo_saida, '') not ilike 'Nio:%'
       and v.criado_em > now() - interval '90 days'
       and not exists (select 1 from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'cancelado_no_portal')
    union all
    -- (g) 0157 (D1): qualificado em andamento, sem fala do cliente há mais de N dias
    select case when l.tem_pedido_nio then 'silencio_com_pedido' else 'silencio_qualificado' end,
           l.lead_id, l.conversa_id, l.venda_id, l.nome, l.ultima_msg_lead_at, 3,
           case when l.tem_pedido_nio
                then format('Sem resposta do cliente há %s dias e com pedido aberto na Nio — insistir (ligar) ou cancelar na Nio e registrar a Saída',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int)
                else format('Qualificado e sem resposta do cliente há %s dias — retomar ou registrar a Saída · Sem resposta',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int) end
      from public.v_leads l
     where l.destino = 'em_andamento' and l.etapa in ('qualificado', 'instalacao') and l.status <> 'aguardando_instalacao'
       and not l.em_espera and l.venda_id is not null
       and l.ultima_msg_lead_at is not null
       and l.ultima_msg_lead_at < now() - make_interval(days => coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'saida_silencio_dias'), 15))    union all
    -- (h) 0157: saída com data de volta que chegou (recusou · momento, fachada em revisão) — vale também para conversa sem venda
    select 'volta_hoje', l.lead_id, l.conversa_id, l.venda_id, l.nome, l.volta_em::timestamptz, 3,
           format('Combinou voltar em %s (%s%s) — retomar o contato ou reabrir', to_char(l.volta_em, 'DD/MM'), l.saida_nome, coalesce(' · ' || l.saida_sub, ''))
      from public.v_leads l
     where l.destino = 'saida' and l.volta_em is not null
       and l.volta_em <= (now() at time zone 'America/Sao_Paulo')::date and l.volta_em > (now() at time zone 'America/Sao_Paulo')::date - 30
       and l.saida_motivo <> 'nao_contatar'
    union all
    -- (i) 0168: exceção da OS na Nio (Operador de OS e OSAB), com o valor em jogo e a ação
    select 'os_excecao', a.pedido, null::uuid, a.venda_id,
           coalesce(nullif(btrim(v.cliente_nome), ''), 'OS ' || a.pedido), coalesce(a.excecao_desde, a.mudou_em), 1,
           format('OS %s na Nio: %s%s%s — %s', a.pedido, coalesce(a.status_ordem, 'sem status'),
                  coalesce(' · ' || nullif(btrim(a.motivo_cancelamento), ''), ''),
                  case when coalesce(v.comissao_prevista, 0) > 0
                       then ' · R$ ' || replace(to_char(v.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end,
                  coalesce(a.acao, 'conferir na Consulta OS'))
      from public.os_andamento a
      left join public.vendas v on v.id = a.venda_id
     where a.excecao
    union all
    -- (i2) 0196: biometria da Nio fora do ar (suspeita automática pelo GED360 ou marcada pelo time)
    select 'biometria_fora', q.id::text, null::uuid, null::uuid, 'Biometria da Nio', q.inicio, 1,
           format('%s desde %s%s · %s venda(s) esperando a biometria — peça à Nio a dispensa e marque "Nio dispensou" em cada ficha; quando voltar, marque "Voltou" (Operações › Biometria)',
                  case when q.confirmada_em is null then 'Biometria da Nio parece fora do ar (GED360 sem biometria nova há ' || q.horas_sem_envio || ' h no horário comercial · confirme no grupo)'
                       else 'Biometria da Nio FORA DO AR' end,
                  to_char(q.inicio at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                  case when q.origem = 'manual' then ' (marcada por ' || coalesce((select u.nome from public.usuarios u where u.id = q.aberta_por), 'time') || ')' else '' end,
                  (select count(*) from public.vendas v where v.status in ('1_vendido', '2_aguardando_instalacao') and v.biometria_status in ('pendente', 'com_risco')))
      from public.biometria_quedas q
     where q.fim is null
    union all
    -- (j) 0175: a conta de hoje não fechou (conferência diária, etapa 6) — uma linha por falha
    select 'conta_nao_fecha', x ->> 'codigo', null::uuid, null::uuid, 'Conferência do dia', c.rodada_em, 1,
           format('A conta não fecha — %s: %s%s', x ->> 'nome', x ->> 'texto', coalesce(' → ' || nullif(x ->> 'fazer', ''), ''))
      from public.conferencias_diarias c
      cross join lateral jsonb_array_elements(c.itens) x
     where c.dia = (now() at time zone 'America/Sao_Paulo')::date and x ->> 'nivel' = 'falha'
    union all
    -- (k) 0182: risco de recompra — venda em andamento com CPF ou endereço repetido (só aviso; decisão do Ricardo, 13/11)
    select 'risco_recompra', rr.venda_id::text, null::uuid, rr.venda_id, coalesce(nullif(btrim(rr.cliente_nome), ''), 'Cliente'), rr.criado_em, 2,
           format('Risco de recompra — %s%s — conferir no portal ANTES de gravar o pedido e marcar "Conferi" na ficha (cliente ou endereço já na base = estorno de 100 %%; recompra = multa de R$ 500)',
                  rr.motivo, case when coalesce(rr.comissao_prevista, 0) > 0
                                  then ' · R$ ' || replace(to_char(rr.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end)
      from public.v_venda_risco_recompra rr
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$function$;

create or replace view public.v_jornada_base with (security_invoker = true) as
 SELECT j.tipo,
    j.chave,
    j.venda_id,
    j.conversa_id,
    j.chatwoot_conversation_id,
    j.nome,
    j.cidade,
    j.plano,
    j.origem,
    j.etapa,
    j.etapa_nome,
    j.precisa_acao OR x.furo OR x.prov_vencido OR x.conf_vencida AS precisa_acao,
        CASE
            WHEN x.furo THEN 'agora'::text
            WHEN (x.prov_vencido OR x.conf_vencida) AND j.nivel <> 'agora'::text THEN 'hoje'::text
            ELSE j.nivel
        END AS nivel,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN ('Passado pela Mari sem dono há '::text ||
            CASE
                WHEN y.min < 60 THEN y.min || ' min'::text
                ELSE (y.min / 60) || ' h'::text
            END) || ' (horário de atendimento) · assumir'::text
            WHEN x.conf_vencida AND j.nivel <> 'agora'::text THEN ('Cliente confirmou há '::text || (z.conf_min / 60)) || ' h · dar o retorno prometido'::text
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN ('Trocar nº provisório do pedido ('::text || y.pedido) || ') pelo nº real do portal'::text
            WHEN x.confirmou AND j.tipo = 'conversa'::text AND NOT j.precisa_acao THEN 'Cliente confirmou · aguardando você'::text
            ELSE j.o_que_fazer
        END AS o_que_fazer,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN 'assumir'::text
            WHEN x.conf_vencida AND j.nivel <> 'agora'::text THEN 'responder'::text
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN 'abrir'::text
            ELSE j.botao
        END AS botao,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN y.handoff_em
            WHEN x.conf_vencida AND j.nivel <> 'agora'::text THEN z.conf_desde
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN y.pedido_em
            WHEN x.confirmou AND j.tipo = 'conversa'::text AND NOT j.precisa_acao THEN z.conf_desde
            ELSE j.desde
        END AS desde,
    j.dono_tipo,
    j.dono_nome,
    j.pendencia,
    j.acao_id,
    j.status_venda,
    j.parceiro_id,
    y.min AS sem_dono_min,
    y.prov AS pedido_provisorio,
    x.confirmou AND NOT x.conf_vencida AS cliente_confirmou,
    z.conf_desde AS confirmou_em
   FROM ( WITH cfg AS (
                 SELECT COALESCE(( SELECT (config_regras.valor #>> '{}'::text[])::integer AS int4
                           FROM config_regras
                          WHERE config_regras.chave = 'prazo_docs_dias'::text), 15) AS d_docs,
                    (now() AT TIME ZONE 'America/Sao_Paulo'::text)::date AS hoje
                ), conv AS (
                 SELECT q.id,
                    q.venda_id,
                    q.nome,
                    q.cidade,
                    q.origem,
                    q.plano_nome,
                    q.coluna,
                    q.itens_total,
                    q.itens_validados,
                    q.chatwoot_conversation_id,
                    q.ultima_em,
                    q.janela_24h_fecha_em,
                    q.contatos_hoje,
                    q.contatos_mes,
                    c_1.chatwoot_agente,
                    c_1.chatwoot_time,
                    c_1.chatwoot_status,
                    COALESCE(c_1.humano_atribuido, false) AS humano_atribuido,
                    COALESCE(c_1.nao_contatar, false) AS nao_contatar,
                    c_1.status AS conv_status,
                    c_1.handoff_motivo,
                    c_1.handoff_em,
                    l.ult_lead,
                    l.ult_resp,
                    l.ult_humano,
                    s.minutos AS sem_resp_min,
                    s.desde AS sem_resp_desde,
                    al.tipo AS alerta,
                    al.em AS alerta_em,
                    bl.id AS bloq_id,
                    bl.motivo AS bloq_motivo,
                    bl.criada_em AS bloq_em
                   FROM v_mari_quadro q
                     JOIN mari_conversas c_1 ON c_1.id = q.id
                     CROSS JOIN LATERAL ( SELECT max(t.created_at) FILTER (WHERE t.papel = 'lead'::text) AS ult_lead,
                            GREATEST(max(t.created_at) FILTER (WHERE t.papel = ANY (ARRAY['mari'::text, 'humano'::text])), ( SELECT max(a.criada_em) AS max
                                   FROM chatwoot_acoes a
                                  WHERE a.conversa_id = q.id AND a.tipo = 'mensagem'::text AND (a.payload ->> 'como'::text) = 'humano'::text AND (a.status = ANY (ARRAY['pendente'::text, 'executando'::text, 'feita'::text]))), c_1.dispensada_em) AS ult_resp,
                            GREATEST(max(t.created_at) FILTER (WHERE t.papel = 'humano'::text), ( SELECT max(a.criada_em) AS max
                                   FROM chatwoot_acoes a
                                  WHERE a.conversa_id = q.id AND a.tipo = 'mensagem'::text AND (a.payload ->> 'como'::text) = 'humano'::text AND (a.status = ANY (ARRAY['pendente'::text, 'executando'::text, 'feita'::text])))) AS ult_humano
                           FROM mari_turnos t
                          WHERE t.conversa_id = q.id) l
                     LEFT JOIN v_mari_sem_resposta s ON s.id = q.id
                     LEFT JOIN LATERAL ( SELECT
                                CASE
                                    WHEN t.texto ~* '(migra[çc][ãa]o|migrar|operadora parceira|outra operadora|desligamento|(pedido|contrato|instala[çc][ãa]o) (foi )?cancelad|\m(tim|claro|vivo)\M ?(ou|,|/) ?\m(tim|claro|vivo)\M)'::text THEN 'golpe'::text
                                    WHEN t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente)'::text THEN 'reclamacao'::text
                                    WHEN t.texto ~* '(descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos)'::text THEN 'desconto'::text
                                    ELSE 'nao_pedi'::text
                                END AS tipo,
                            t.created_at AS em
                           FROM mari_turnos t
                          WHERE t.conversa_id = q.id AND t.papel = 'lead'::text AND t.created_at > (now() - '7 days'::interval) AND t.created_at > COALESCE(l.ult_humano, '-infinity'::timestamp with time zone) AND (t.texto ~* '(migra[çc][ãa]o|migrar|operadora parceira|outra operadora|desligamento|(pedido|contrato|instala[çc][ãa]o) (foi )?cancelad|\m(tim|claro|vivo)\M ?(ou|,|/) ?\m(tim|claro|vivo)\M)'::text OR t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente|descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos|n[aã]o (pedi|solicitei|autorizei)|como (vc|voc[eê]s?) (conseguiu|pegou|achou) meu|n[aã]o me (mande|chame|ligue))'::text)
                          ORDER BY t.created_at DESC
                         LIMIT 1) al ON true
                     LEFT JOIN LATERAL ( SELECT a.id,
                            COALESCE(a.payload ->> 'rotulo'::text, a.momento) || COALESCE(' — '::text || a.erro, ''::text) AS motivo,
                            a.criada_em
                           FROM chatwoot_acoes a
                          WHERE a.conversa_id = q.id AND a.status = 'bloqueada'::text AND a.criada_em > (now() - '7 days'::interval)
                          ORDER BY a.criada_em
                         LIMIT 1) bl ON true
                  WHERE c_1.canal = 'whatsapp'::text AND COALESCE(c_1.telefone, ''::text) !~~ '5500000000%'::text
                ), sinal AS (
                 SELECT cv.id,
                    cv.venda_id,
                    cv.nome,
                    cv.cidade,
                    cv.origem,
                    cv.plano_nome,
                    cv.coluna,
                    cv.itens_total,
                    cv.itens_validados,
                    cv.chatwoot_conversation_id,
                    cv.ultima_em,
                    cv.janela_24h_fecha_em,
                    cv.contatos_hoje,
                    cv.contatos_mes,
                    cv.chatwoot_agente,
                    cv.chatwoot_time,
                    cv.chatwoot_status,
                    cv.humano_atribuido,
                    cv.nao_contatar,
                    cv.conv_status,
                    cv.handoff_motivo,
                    cv.handoff_em,
                    cv.ult_lead,
                    cv.ult_resp,
                    cv.ult_humano,
                    cv.sem_resp_min,
                    cv.sem_resp_desde,
                    cv.alerta,
                    cv.alerta_em,
                    cv.bloq_id,
                    cv.bloq_motivo,
                    cv.bloq_em,
                        CASE
                            WHEN cv.nao_contatar OR cv.coluna = 'encerrada'::text THEN NULL::text
                            WHEN cv.bloq_id IS NOT NULL THEN ('Mensagem não saiu ('::text || cv.bloq_motivo) || ') · mandar à mão'::text
                            WHEN cv.sem_resp_min IS NOT NULL THEN ('Cliente sem resposta há '::text || cv.sem_resp_min) || ' min (a Mari não respondeu)'::text
                            WHEN cv.alerta = 'golpe'::text THEN 'Cliente citou migração, cancelamento ou outra operadora · possível golpe · humano agora'::text
                            WHEN cv.alerta = 'reclamacao'::text THEN 'Reclamação ou já cliente Nio · humano agora'::text
                            WHEN cv.alerta = 'desconto'::text THEN 'Pediu desconto · humano responde (só a tabela da Nio)'::text
                            WHEN cv.alerta = 'nao_pedi'::text THEN '"Não pedi contato" · humano responde e encerra'::text
                            WHEN cv.conv_status = 'handoff_realizado'::text AND (COALESCE(cv.handoff_motivo, ''::text) <> ALL (ARRAY['dados_completos'::text, 'recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'sem_contato'::text])) AND COALESCE(cv.ult_humano, '-infinity'::timestamp with time zone) < COALESCE(cv.handoff_em, '-infinity'::timestamp with time zone) THEN 'Pediu um consultor · ninguém do time falou ainda'::text
                            WHEN (cv.conv_status = 'handoff_realizado'::text OR cv.humano_atribuido OR cv.chatwoot_agente IS NOT NULL) AND cv.ult_lead > COALESCE(cv.ult_resp, '-infinity'::timestamp with time zone) AND cv.ult_lead > (now() - '7 days'::interval) AND cliente_confirmou_desde(cv.id, cv.ult_resp) IS NULL THEN
                            CASE
                                WHEN cv.coluna = 'retomada'::text THEN 'Voltou a falar depois do time · responder'::text
                                WHEN cv.conv_status = 'handoff_realizado'::text AND (cv.handoff_motivo = ANY (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'ja_cliente_nio'::text, 'sem_contato'::text])) THEN ('Voltou a escrever depois de sair ('::text ||
                                CASE cv.handoff_motivo
                                    WHEN 'sem_cobertura'::text THEN 'sem cobertura'::text
                                    WHEN 'fora_de_area'::text THEN 'fora da área'::text
                                    WHEN 'recusa_compra'::text THEN 'recusou'::text
                                    WHEN 'ja_cliente_nio'::text THEN 'já é cliente Nio'::text
                                    ELSE 'sem contato'::text
                                END) || ') · responder'::text
                                ELSE 'Cliente escreveu · responder'::text
                            END
                            ELSE NULL::text
                        END AS alerta_txt,
                        CASE
                            WHEN cv.bloq_id IS NOT NULL THEN cv.bloq_em
                            WHEN cv.sem_resp_min IS NOT NULL THEN cv.sem_resp_desde
                            WHEN cv.alerta IS NOT NULL THEN cv.alerta_em
                            WHEN cv.conv_status = 'handoff_realizado'::text AND (cv.handoff_motivo = ANY (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'ja_cliente_nio'::text, 'sem_contato'::text])) THEN cv.ult_lead
                            WHEN cv.conv_status = 'handoff_realizado'::text AND COALESCE(cv.ult_humano, '-infinity'::timestamp with time zone) < COALESCE(cv.handoff_em, '-infinity'::timestamp with time zone) THEN cv.handoff_em
                            ELSE cv.ult_lead
                        END AS alerta_desde,
                        CASE
                            WHEN cv.nao_contatar THEN NULL::text
                            WHEN cv.chatwoot_agente IS NOT NULL THEN 'pessoa'::text
                            WHEN cv.humano_atribuido THEN 'pessoa'::text
                            WHEN cv.chatwoot_status = 'resolved'::text THEN NULL::text
                            WHEN cv.chatwoot_time IS NOT NULL THEN 'time'::text
                            ELSE 'mari'::text
                        END AS dono_tipo,
                        CASE
                            WHEN cv.nao_contatar THEN NULL::text
                            WHEN cv.chatwoot_agente IS NOT NULL THEN cv.chatwoot_agente
                            WHEN cv.humano_atribuido THEN 'time (assumida)'::text
                            WHEN cv.chatwoot_status = 'resolved'::text THEN NULL::text
                            WHEN cv.chatwoot_time IS NOT NULL THEN 'time '::text || cv.chatwoot_time
                            ELSE 'Mari'::text
                        END AS dono_nome
                   FROM conv cv
                ), vend AS (
                 SELECT v.id,
                    v.criado_em,
                    v.criado_por,
                    v.status,
                    v.motivo_saida,
                    v.interesse_futuro_em,
                    v.origem,
                    v.origem_ref,
                    v.cliente_nome,
                    v.cliente_cpf_cnpj,
                    v.cliente_whatsapp,
                    v.cliente_email,
                    v.segmento,
                    v.cep,
                    v.logradouro,
                    v.numero,
                    v.complemento,
                    v.bairro,
                    v.cidade,
                    v.uf,
                    v.plano_id,
                    v.forma_pagamento,
                    v.vencimento_dia,
                    v.comissao_prevista,
                    v.comissao_paga,
                    v.ciclo_pago,
                    v.estorno_previsto,
                    v.nio_pedido,
                    v.nio_contrato,
                    v.nio_situacao,
                    v.nio_pendencia_cod,
                    v.nio_pendencia_desc,
                    v.biometria_status,
                    v.biometria_em,
                    v.vendido_em,
                    v.agendamento_registrado_em,
                    v.instalacao_agendada_para,
                    v.instalado_em,
                    v.ativado_em,
                    v.docs_entregues_em,
                    v.vendedor_id,
                    v.trava_cobertura,
                    v.trava_area,
                    v.trava_sem_produto_ativo,
                    v.trava_sem_cancelamento_30d,
                    v.trava_cpf_valido,
                    v.trava_contato_confirmado,
                    v.nio_osab_em,
                    v.nio_venda_valida,
                    v.valor_mensal,
                    v.comissao_nominal,
                    v.comissao_adicionais,
                    v.bonus_transicao_previsto,
                    v.bonus_nmei_previsto,
                    v.bonus_m10_potencial,
                    v.primeiro_vencimento,
                    v.dfv_viabilidade,
                    v.dfv_consultado_em,
                    v.dfv_consultado_por,
                    v.dfv_faixa_credito,
                    v.dfv_classificacao,
                    v.dfv_hp_livre,
                    v.dfv_hcs,
                    v.dfv_dispensado,
                    v.dfv_dispensa_motivo,
                    v.dfv_origem,
                    v.dfv_resultado,
                    v.dfv_particao,
                    v.observacoes,
                    v.nio_viab_resultado,
                    v.nio_viab_velocidade,
                    v.nio_viab_interesse_id,
                    v.nio_viab_endereco_id,
                    v.nio_viab_em,
                    v.nio_viab_origem,
                    v.credito_resultado,
                    v.credito_em,
                    v.biometria_link,
                    v.biometria_link_enviado_em,
                    v.biometria_validada_em,
                    v.instalacao_preferencia,
                    v.instalacao_turno,
                    v.nio_viab_endereco_portal,
                    v.nio_pedido_em,
                    v.parceiro_id,
                    v.conferencia_status,
                    v.conferencia_motivo,
                    v.conferencia_obs,
                    v.conferencia_em,
                    v.conferencia_por,
                    v.conferencia_prazo_ate,
                    v.nio_viab_por,
                    v.ponto_referencia,
                    v.nio_os,
                    v.nio_os_em,
                    jornada_etapa(v.status, v.nio_pedido, v.credito_resultado) AS etapa,
                    p.nome_curto AS plano_curto,
                    u.nome AS vendedor_nome,
                    pe.id AS pend_id,
                    pe.revisar_em AS pend_revisar,
                    pe.aberta_em AS pend_desde,
                    pm.nome AS pend_nome,
                        CASE pe.quem_destrava
                            WHEN 'nio'::text THEN 'Nio'::text
                            WHEN 'rogerio'::text THEN 'Rogério'::text
                            WHEN 'cliente'::text THEN 'cliente'::text
                            ELSE 'nosso time'::text
                        END AS pend_quem,
                    s.id AS conv_id,
                    s.chatwoot_conversation_id AS cw_id,
                    s.alerta_txt,
                    s.alerta_desde,
                    s.bloq_id,
                    s.dono_tipo AS conv_dono_tipo,
                    s.dono_nome AS conv_dono_nome,
                    s.id IS NOT NULL AND COALESCE(s.chatwoot_conversation_id, ''::text) <> ''::text AND COALESCE(s.dono_tipo, 'mari'::text) = 'mari'::text AND NOT s.nao_contatar AS sem_dono,
                    COALESCE(v.nio_viab_resultado = 'viavel'::text AND v.nio_viab_em >= (now() - '7 days'::interval), false) AS viab_ok
                   FROM vendas v
                     LEFT JOIN config_planos p ON p.id = v.plano_id
                     LEFT JOIN usuarios u ON u.id = v.vendedor_id
                     LEFT JOIN venda_pendencias pe ON pe.venda_id = v.id AND pe.encerrada_em IS NULL
                     LEFT JOIN config_motivos_pendencia pm ON pm.codigo = pe.motivo
                     LEFT JOIN LATERAL ( SELECT x_1.id,
                            x_1.venda_id,
                            x_1.nome,
                            x_1.cidade,
                            x_1.origem,
                            x_1.plano_nome,
                            x_1.coluna,
                            x_1.itens_total,
                            x_1.itens_validados,
                            x_1.chatwoot_conversation_id,
                            x_1.ultima_em,
                            x_1.janela_24h_fecha_em,
                            x_1.contatos_hoje,
                            x_1.contatos_mes,
                            x_1.chatwoot_agente,
                            x_1.chatwoot_time,
                            x_1.chatwoot_status,
                            x_1.humano_atribuido,
                            x_1.nao_contatar,
                            x_1.conv_status,
                            x_1.handoff_motivo,
                            x_1.handoff_em,
                            x_1.ult_lead,
                            x_1.ult_resp,
                            x_1.ult_humano,
                            x_1.sem_resp_min,
                            x_1.sem_resp_desde,
                            x_1.alerta,
                            x_1.alerta_em,
                            x_1.bloq_id,
                            x_1.bloq_motivo,
                            x_1.bloq_em,
                            x_1.alerta_txt,
                            x_1.alerta_desde,
                            x_1.dono_tipo,
                            x_1.dono_nome
                           FROM sinal x_1
                          WHERE x_1.venda_id = v.id
                          ORDER BY x_1.ultima_em DESC NULLS LAST
                         LIMIT 1) s ON true
                ), vr AS (
                 SELECT vd.id,
                    vd.criado_em,
                    vd.criado_por,
                    vd.status,
                    vd.motivo_saida,
                    vd.interesse_futuro_em,
                    vd.origem,
                    vd.origem_ref,
                    vd.cliente_nome,
                    vd.cliente_cpf_cnpj,
                    vd.cliente_whatsapp,
                    vd.cliente_email,
                    vd.segmento,
                    vd.cep,
                    vd.logradouro,
                    vd.numero,
                    vd.complemento,
                    vd.bairro,
                    vd.cidade,
                    vd.uf,
                    vd.plano_id,
                    vd.forma_pagamento,
                    vd.vencimento_dia,
                    vd.comissao_prevista,
                    vd.comissao_paga,
                    vd.ciclo_pago,
                    vd.estorno_previsto,
                    vd.nio_pedido,
                    vd.nio_contrato,
                    vd.nio_situacao,
                    vd.nio_pendencia_cod,
                    vd.nio_pendencia_desc,
                    vd.biometria_status,
                    vd.biometria_em,
                    vd.vendido_em,
                    vd.agendamento_registrado_em,
                    vd.instalacao_agendada_para,
                    vd.instalado_em,
                    vd.ativado_em,
                    vd.docs_entregues_em,
                    vd.vendedor_id,
                    vd.trava_cobertura,
                    vd.trava_area,
                    vd.trava_sem_produto_ativo,
                    vd.trava_sem_cancelamento_30d,
                    vd.trava_cpf_valido,
                    vd.trava_contato_confirmado,
                    vd.nio_osab_em,
                    vd.nio_venda_valida,
                    vd.valor_mensal,
                    vd.comissao_nominal,
                    vd.comissao_adicionais,
                    vd.bonus_transicao_previsto,
                    vd.bonus_nmei_previsto,
                    vd.bonus_m10_potencial,
                    vd.primeiro_vencimento,
                    vd.dfv_viabilidade,
                    vd.dfv_consultado_em,
                    vd.dfv_consultado_por,
                    vd.dfv_faixa_credito,
                    vd.dfv_classificacao,
                    vd.dfv_hp_livre,
                    vd.dfv_hcs,
                    vd.dfv_dispensado,
                    vd.dfv_dispensa_motivo,
                    vd.dfv_origem,
                    vd.dfv_resultado,
                    vd.dfv_particao,
                    vd.observacoes,
                    vd.nio_viab_resultado,
                    vd.nio_viab_velocidade,
                    vd.nio_viab_interesse_id,
                    vd.nio_viab_endereco_id,
                    vd.nio_viab_em,
                    vd.nio_viab_origem,
                    vd.credito_resultado,
                    vd.credito_em,
                    vd.biometria_link,
                    vd.biometria_link_enviado_em,
                    vd.biometria_validada_em,
                    vd.instalacao_preferencia,
                    vd.instalacao_turno,
                    vd.nio_viab_endereco_portal,
                    vd.nio_pedido_em,
                    vd.parceiro_id,
                    vd.conferencia_status,
                    vd.conferencia_motivo,
                    vd.conferencia_obs,
                    vd.conferencia_em,
                    vd.conferencia_por,
                    vd.conferencia_prazo_ate,
                    vd.nio_viab_por,
                    vd.ponto_referencia,
                    vd.nio_os,
                    vd.nio_os_em,
                    vd.etapa,
                    vd.plano_curto,
                    vd.vendedor_nome,
                    vd.pend_id,
                    vd.pend_revisar,
                    vd.pend_desde,
                    vd.pend_nome,
                    vd.pend_quem,
                    vd.conv_id,
                    vd.cw_id,
                    vd.alerta_txt,
                    vd.alerta_desde,
                    vd.bloq_id,
                    vd.conv_dono_tipo,
                    vd.conv_dono_nome,
                    vd.sem_dono,
                    vd.viab_ok,
                    cfg.d_docs,
                        CASE
                            WHEN vd.status = 'saida'::text THEN jsonb_build_array('fora', COALESCE(vd.motivo_saida, 'Saída'::text) || COALESCE(' · volta '::text || to_char(vd.interesse_futuro_em::timestamp with time zone, 'DD/MM'::text), ''::text), NULL::unknown, NULL::unknown)
                            WHEN vd.alerta_txt IS NOT NULL THEN jsonb_build_array('agora', vd.alerta_txt,
                            CASE
                                WHEN vd.bloq_id IS NOT NULL THEN 'manual'::text
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'responder'::text
                            END, vd.alerta_desde)
                            WHEN vd.pend_id IS NOT NULL AND vd.pend_revisar <= cfg.hoje THEN jsonb_build_array('agora', (('⏰ Revisar hoje: '::text || COALESCE(vd.pend_nome, 'pendência'::text)) || ' · '::text) || vd.pend_quem, 'pendencia', vd.pend_desde)
                            WHEN vd.pend_id IS NOT NULL THEN jsonb_build_array('espera', (((('⏸ Aguardando '::text || vd.pend_quem) || ' · '::text) || COALESCE(vd.pend_nome, 'pendência'::text)) || ' · revisar '::text) || to_char(vd.pend_revisar::timestamp with time zone, 'DD/MM'::text), 'pendencia', vd.pend_desde)
                            WHEN vd.nio_venda_valida = false THEN jsonb_build_array('agora', 'A Nio marcou a venda como inválida · avisar o Ricardo', 'abrir', vd.nio_osab_em)
                            WHEN vd.etapa = 2 AND vd.origem = 'parceiro_pap'::text AND vd.conferencia_status = 'pendente'::text THEN jsonb_build_array(
                            CASE
                                WHEN vd.conferencia_prazo_ate < now() THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, 'Conferir a venda do parceiro', 'conferencia', vd.criado_em)
                            WHEN vd.etapa = 2 AND vd.origem = 'parceiro_pap'::text AND (vd.conferencia_status = ANY (ARRAY['devolvida'::text, 'reprovada'::text])) THEN jsonb_build_array('espera',
                            CASE vd.conferencia_status
                                WHEN 'devolvida'::text THEN 'Devolvida ao parceiro · esperando correção'::text
                                ELSE 'Reprovada na conferência'::text
                            END, 'abrir', vd.criado_em)
                            WHEN vd.etapa = 2 AND vd.credito_resultado = 'negado'::text THEN jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'abrir', vd.credito_em)
                            WHEN vd.etapa = 2 AND NOT vd.viab_ok THEN jsonb_build_array('hoje',
                            CASE
                                WHEN vd.nio_viab_resultado = ANY (ARRAY['sem_viabilidade'::text, 'nao_encontrado'::text, 'posse'::text]) THEN ('Portal: '::text ||
                                CASE vd.nio_viab_resultado
                                    WHEN 'sem_viabilidade'::text THEN 'sem viabilidade'::text
                                    WHEN 'nao_encontrado'::text THEN 'endereço não encontrado'::text
                                    ELSE 'endereço já tem Nio'::text
                                END) || ' · conferir no DFV: endereço viável a até 200 m → formulário da Nio + pendência'::text
                                WHEN vd.nio_viab_resultado = 'viavel'::text THEN 'Viabilidade vencida (> 7 dias) · consultar de novo no portal'::text
                                ELSE 'Consultar a viabilidade no portal'::text
                            END,
                            CASE
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'viabilidade'::text
                            END, vd.criado_em)
                            WHEN vd.etapa = 2 AND vd.credito_resultado = 'pendente'::text THEN jsonb_build_array('hoje', 'Crédito pendente na Nio · conferir no portal e gravar o resultado',
                            CASE
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'credito'::text
                            END, COALESCE(vd.credito_em, vd.nio_viab_em, vd.criado_em))
                            WHEN vd.etapa = 2 THEN jsonb_build_array('hoje', 'Viável · rodar o crédito no portal e gravar o resultado',
                            CASE
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'credito'::text
                            END, COALESCE(vd.nio_viab_em, vd.criado_em))
                            WHEN vd.etapa = 3 AND vd.credito_resultado = 'negado'::text THEN jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'biometria', vd.credito_em)
                            WHEN vd.etapa = 3 THEN jsonb_build_array(
                            CASE
                                WHEN COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em) < (now() - '02:00:00'::interval) THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, 'Crédito aprovado · no portal: forma de pagamento, agenda e OS · gravar a OS e a data'::text, 'os', COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em))
                            WHEN vd.etapa = 4 AND vd.instalacao_agendada_para IS NULL THEN jsonb_build_array('agora', 'OS aberta sem data · gravar a agenda do portal · há '::text || _h_txt(COALESCE(vd.biometria_validada_em, vd.vendido_em)), 'agendar', COALESCE(vd.biometria_validada_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND (vd.nio_pendencia_cod IS NOT NULL OR vd.nio_pendencia_desc IS NOT NULL) THEN jsonb_build_array('hoje', "left"('Pendência Nio · '::text || concat_ws(' · '::text, vd.nio_pendencia_cod, vd.nio_pendencia_desc), 90) || ' · reagendar'::text, 'agendar', COALESCE(vd.nio_osab_em, vd.agendamento_registrado_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'com_risco'::text THEN jsonb_build_array('hoje', 'Biometria com risco · conferir no portal', 'biometria', vd.biometria_em)
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND (EXISTS ( SELECT 1 FROM biometria_quedas q WHERE q.fim IS NULL)) THEN jsonb_build_array('hoje', 'Biometria da Nio fora do ar · pedir à Nio a dispensa e marcar "Nio dispensou" na ficha'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND (EXISTS ( SELECT 1 FROM biometria_quedas q WHERE q.fim IS NOT NULL AND q.fim > (now() - '48:00:00'::interval) AND COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em) < q.fim)) THEN jsonb_build_array('agora', ('A biometria da Nio voltou · cliente esperando há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))) || ' · conferir o link (pedir novo se expirou) e falar com ele'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em) < (now() - '72:00:00'::interval) THEN jsonb_build_array('agora', ('Biometria pendente há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))) || ' · ligar para o cliente'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em) < (now() - '24:00:00'::interval) THEN jsonb_build_array('hoje', ('Biometria pendente há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))) || ' · a Mari lembrou; consultar e falar com o cliente'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text THEN jsonb_build_array('espera', 'Esperando a biometria do cliente · link da Nio há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em)), 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND vd.biometria_validada_em < (now() - '48:00:00'::interval) AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) THEN jsonb_build_array('agora', ('Cartão sem cadastro há '::text || _h_txt(vd.biometria_validada_em)) || ' · ligar: a visita depende do cadastro no link da Nio (conferir a OS)'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) THEN jsonb_build_array('espera', 'Biometria aprovada · esperando o cliente cadastrar o cartão no link da Nio (a Mari avisou)'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date < cfg.hoje THEN jsonb_build_array('hoje', ('Instalação era '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' e a Nio não deu baixa · conferir no portal'::text, 'agendar', vd.instalacao_agendada_para)
                            WHEN vd.etapa = 4 THEN jsonb_build_array('espera', (('Instalação '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) ||
                            CASE
                                WHEN COALESCE(vd.instalacao_turno, ''::text) = 'tarde'::text OR EXTRACT(hour FROM (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)) >= 12::numeric THEN ' à tarde'::text
                                ELSE ' de manhã'::text
                            END) || ' · com a Nio'::text, 'agendar', vd.agendamento_registrado_em)
                            WHEN vd.etapa = 5 AND vd.status = '3_instalado'::text AND vd.docs_entregues_em IS NULL AND vd.instalado_em IS NOT NULL THEN jsonb_build_array(
                            CASE
                                WHEN (vd.instalado_em + make_interval(days => cfg.d_docs)) < now() THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, ((('Documentos à Nio · prazo '::text || to_char(((vd.instalado_em + make_interval(days => cfg.d_docs)) AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' ('::text) || cfg.d_docs) || ' dias)'::text, 'docs', vd.instalado_em)
                            ELSE jsonb_build_array('ok', 'Instalada · conta na meta', 'abrir', COALESCE(vd.ativado_em, vd.instalado_em))
                        END AS r
                   FROM vend vd
                     CROSS JOIN cfg
                )
         SELECT 'venda'::text AS tipo,
            vr.id::text AS chave,
            vr.id AS venda_id,
            vr.conv_id AS conversa_id,
            vr.cw_id AS chatwoot_conversation_id,
            vr.cliente_nome AS nome,
            vr.cidade,
            COALESCE(vr.plano_curto, ''::text) AS plano,
            vr.origem,
            vr.etapa,
            jornada_nome(vr.etapa) AS etapa_nome,
            (vr.r ->> 0) = ANY (ARRAY['agora'::text, 'hoje'::text]) AS precisa_acao,
            vr.r ->> 0 AS nivel,
            vr.r ->> 1 AS o_que_fazer,
            vr.r ->> 2 AS botao,
            NULLIF(vr.r ->> 3, ''::text)::timestamp with time zone AS desde,
            COALESCE(vr.conv_dono_tipo,
                CASE
                    WHEN vr.vendedor_id IS NOT NULL THEN 'pessoa'::text
                    ELSE NULL::text
                END) AS dono_tipo,
            COALESCE(vr.conv_dono_nome, vr.vendedor_nome) AS dono_nome,
            vr.pend_id IS NOT NULL AS pendencia,
            vr.bloq_id AS acao_id,
            vr.status AS status_venda,
            'dharma'::text AS parceiro_id
           FROM vr
        UNION ALL
         SELECT 'conversa'::text AS tipo,
            'c:'::text || s.id::text AS chave,
            NULL::uuid AS venda_id,
            s.id AS conversa_id,
            s.chatwoot_conversation_id,
            COALESCE(NULLIF(initcap(split_part(btrim(COALESCE(s.nome, ''::text)), ' '::text, 1)), ''::text), 'Contato'::text) AS nome,
            s.cidade,
            COALESCE(s.plano_nome, ''::text) AS plano,
            s.origem,
            1 AS etapa,
            jornada_nome(1) AS etapa_nome,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL THEN false
                    WHEN e.ativa AND e.espera_ate <= now() THEN true
                    ELSE s.alerta_txt IS NOT NULL OR s.coluna = 'completo'::text
                END AS precisa_acao,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL THEN 'espera'::text
                    WHEN e.ativa AND e.espera_ate <= now() THEN 'hoje'::text
                    WHEN s.alerta_txt IS NOT NULL OR s.coluna = 'completo'::text THEN 'agora'::text
                    ELSE 'espera'::text
                END AS nivel,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL THEN (('⏸ Aguardando · '::text || COALESCE(e.espera_motivo, 'cliente'::text)) || ' · até '::text) || to_char((e.espera_ate AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)
                    WHEN e.ativa AND e.espera_ate <= now() THEN ((('Retomar · '::text || COALESCE(e.espera_motivo, 'cliente'::text)) || ' (combinado para '::text) || to_char((e.espera_ate AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ')'::text
                    WHEN s.alerta_txt IS NOT NULL THEN s.alerta_txt
                    WHEN s.coluna = 'completo'::text THEN 'Dados completos e a venda não nasceu · ver o erro na tela Mari'::text
                    WHEN s.dono_tipo = ANY (ARRAY['pessoa'::text, 'time'::text]) THEN ('Com '::text || s.dono_nome) || ' · esperando o cliente'::text
                    ELSE ((('Mari atendendo · '::text || COALESCE(s.itens_validados, 0::bigint)) || '/'::text) || COALESCE(s.itens_total, 0::bigint)) || ' dados'::text
                END AS o_que_fazer,
                CASE
                    WHEN s.bloq_id IS NOT NULL THEN 'manual'::text
                    WHEN s.dono_tipo = 'mari'::text OR s.dono_tipo IS NULL THEN 'assumir'::text
                    ELSE 'responder'::text
                END AS botao,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL OR e.ativa AND e.espera_ate <= now() THEN e.espera_ate
                    WHEN s.alerta_txt IS NOT NULL THEN s.alerta_desde
                    WHEN s.coluna = 'completo'::text THEN s.handoff_em
                    ELSE s.ultima_em
                END AS desde,
            s.dono_tipo,
            s.dono_nome,
            COALESCE(e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL, false) AS pendencia,
            s.bloq_id AS acao_id,
            NULL::text AS status_venda,
            'dharma'::text AS parceiro_id
           FROM sinal s
             LEFT JOIN LATERAL ( SELECT me.espera_ate,
                    me.espera_motivo,
                    me.espera_ate IS NOT NULL AND COALESCE(s.ult_lead, '-infinity'::timestamp with time zone) <= me.espera_em AS ativa
                   FROM mari_conversas me
                  WHERE me.id = s.id) e ON true
          WHERE s.venda_id IS NULL AND s.coluna <> 'encerrada'::text) j
     LEFT JOIN mari_conversas c ON c.id = j.conversa_id
     LEFT JOIN vendas vv ON vv.id = j.venda_id
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN c.handoff_em IS NOT NULL AND c.handoff_em > (now() - '30 days'::interval) AND (c.status = 'handoff_realizado'::text OR j.venda_id IS NOT NULL) AND (COALESCE(c.handoff_motivo, ''::text) <> ALL (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'sem_contato'::text, 'ja_cliente_nio'::text])) AND COALESCE(j.dono_tipo, 'mari'::text) <> 'pessoa'::text AND NOT COALESCE(c.nao_contatar, false) AND (j.nivel <> ALL (ARRAY['ok'::text, 'fora'::text])) AND NOT j.pendencia AND COALESCE(j.status_venda, ''::text) <> 'saida'::text THEN minutos_uteis(c.handoff_em, now(), c.cidade)
                    ELSE NULL::integer
                END AS min,
            c.handoff_em,
            COALESCE(vv.nio_pedido, ''::text) ~~* 'PROV-%'::text AS prov,
            vv.nio_pedido AS pedido,
            COALESCE(vv.nio_pedido_em, vv.criado_em) AS pedido_em) y
     CROSS JOIN LATERAL ( SELECT q.conf_desde,
                CASE
                    WHEN q.conf_desde IS NOT NULL THEN minutos_uteis(q.conf_desde, now(), c.cidade)
                    ELSE NULL::integer
                END AS conf_min
           FROM ( SELECT
                        CASE
                            WHEN c.id IS NOT NULL AND (c.status = 'handoff_realizado'::text OR COALESCE(c.humano_atribuido, false) OR c.chatwoot_agente IS NOT NULL) AND NOT COALESCE(c.nao_contatar, false) AND NOT j.pendencia AND (j.nivel <> ALL (ARRAY['ok'::text, 'fora'::text])) AND COALESCE(j.status_venda, ''::text) <> 'saida'::text THEN cliente_confirmou_desde(c.id, NULL::timestamp with time zone)
                            ELSE NULL::timestamp with time zone
                        END AS conf_desde) q) z
     CROSS JOIN LATERAL ( SELECT COALESCE(y.min, 0) > 30 AS furo,
            COALESCE(y.prov AND COALESCE(j.status_venda, ''::text) <> 'saida'::text AND y.pedido_em < (now() - '24:00:00'::interval), false) AS prov_vencido,
            z.conf_desde IS NOT NULL AS confirmou,
            COALESCE(z.conf_desde IS NOT NULL AND NOT j.precisa_acao AND z.conf_min >= COALESCE(( SELECT (config_regras.valor #>> '{}'::text[])::integer AS int4
                   FROM config_regras
                  WHERE config_regras.chave = 'confirmacao_retorno_min'::text), 240), false) AS conf_vencida) x;

notify pgrst, 'reload schema';

commit;
