-- NIOGEN | supabase/migrations/0301_radar_biometria_desligado.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11 ~21h15: "Remove o recurso que monitora a Biometria da Nio e consequentemente da tela da Live."
-- O radar (0196/0197) abria uma "queda" quando o GED360 passava 2,5 h de dia útil sem biometria nova; a queda aparecia no Conferir
-- da Live, pintava as vendas de "Biometria da Nio fora do ar" e, ao fechar, a Mari avisava os clientes que "o sistema voltou".
-- Desligar sem refazer as ~8 funções que leem biometria_quedas (porta, v_jornada, live_conferir, cadência 0278…): sem queda aberta,
-- todas elas não acham nada e seguem como se o radar não existisse.
--  (1) config_regras.biometria_queda ganha "ligado": false (religar = true, sem migration).
--  (2) biometria_queda_conferir(): com o radar desligado, não abre nem fecha queda (sai na primeira linha). Resto = 0197.
--  (3) biometria_queda_marcar('fora'): recusa com o radar desligado (ninguém abre queda à mão). 'voltou' segue (não há o que fechar).
--  (4) A queda aberta hoje (suspeita automática de 18/11 13h40) é APAGADA, não fechada: fechar dispararia a mensagem
--      "mari_bio_voltou" (0278) para os clientes com link da biometria enviado antes — aviso falso.
-- Regra 20: (1) nenhum estado de lead novo; (2) não toca a porta; (3) quem muda a queda segue sendo função do banco; (4) sem fonte
-- nova; (5) nada novo a conferir (o radar some). "Nio dispensou a biometria" na ficha continua (não depende do radar).
begin;

update public.config_regras
   set valor = coalesce(valor, '{}'::jsonb) || '{"ligado": false}'::jsonb,
       descricao = '0197/0301: suspeita automática de biometria da Nio fora do ar — DESLIGADA em 18/11/2026 (Ricardo: "remove o recurso que monitora a Biometria da Nio"); "ligado": true religa. dias_semana ISO, sem feriado, entre hora_inicio e hora_fim, com horas_sem_envio inteiras sem biometria nova no GED360; a marcada à mão fecha com X biometrias novas.',
       atualizado_em = now()
 where chave = 'biometria_queda';

create or replace function public.biometria_queda_conferir()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  cfg  jsonb := coalesce((select valor from public.config_regras where chave = 'biometria_queda'), '{}'::jsonb);
  h    numeric := coalesce((cfg ->> 'horas_sem_envio')::numeric, 2.5);
  hi   int := coalesce((cfg ->> 'hora_inicio')::int, 9);
  hf   int := coalesce((cfg ->> 'hora_fim')::int, 18);
  nf   int := coalesce((cfg ->> 'novas_para_fechar_manual')::int, 3);
  dias int[] := coalesce((select array_agg(x::int) from jsonb_array_elements_text(cfg -> 'dias_semana') x), array[1, 2, 3, 4, 5]);
  agora timestamp := now() at time zone 'America/Sao_Paulo';
  janela_ini timestamp := agora - make_interval(mins => (h * 60)::int);
  ult  timestamptz;
  q    public.biometria_quedas;
begin
  if coalesce((cfg ->> 'ligado')::boolean, true) = false then return; end if;   -- 0301: radar desligado
  select max(data_envio) into ult from public.nio_biometria where parceiro_id = 'dharma';
  if ult is null then return; end if;
  select * into q from public.biometria_quedas where fim is null order by inicio desc limit 1;
  if q.id is not null then
    if (q.origem = 'auto' and ult > q.inicio)
       or (q.origem = 'manual' and (select count(*) from public.nio_biometria b where b.data_envio > q.inicio) >= nf) then
      update public.biometria_quedas set fim = now(), fechada_como = 'auto' where id = q.id;
    end if;
    return;
  end if;
  -- As h horas inteiras dentro do expediente de um dia útil (sem feriado: mari_dia_permitido).
  if extract(isodow from agora)::int = any (dias)
     and janela_ini::date = agora::date
     and extract(hour from janela_ini) >= hi and agora < date_trunc('day', agora) + make_interval(hours => hf)
     and public.mari_dia_permitido(agora::date, null)
     and ult < now() - make_interval(mins => (h * 60)::int)
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
    -- 0301: radar desligado — ninguém abre queda (nem à mão).
    if coalesce((select (valor ->> 'ligado')::boolean from public.config_regras where chave = 'biometria_queda'), true) = false then
      raise exception 'O radar da biometria da Nio está desligado (Ricardo, 18/11/2026).';
    end if;
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

-- (4) a suspeita aberta some sem "voltar" (fechar mandaria o aviso falso da Mari).
delete from public.biometria_quedas where fim is null;

commit;
