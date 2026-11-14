-- NIOGEN | supabase/migrations/0197_radar_biometria_calibrado.sql | 14/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 14/11: a biometria da Nio "parou dia 11 e ontem no final do dia; hoje (14) deve ser por ser final de semana".
-- O GED360 confirma: 11/11 nada entre 11h e 21h; 13/11 minguou a partir das 16h; dia útil normal = 5 a 19 biometrias por hora
-- entre 9h e 18h; sábado quase nada. Calibração da suspeita automática (0196): só dia útil (seg–sex, sem feriado), entre 9h e 18h,
-- 2,5 h sem biometria nova. Simulado nas leituras de 15 min de 07 a 14/11: dispara só em 11/11, às 13h45 (com 2 h dava alarme falso
-- em 10/11 às 11h, manhã lenta).
-- O fim do dia (como 13/11) não dá para separar do movimento que cai à noite: ali vale o botão "Biometria da Nio fora do ar".

begin;

update public.config_regras
   set valor = '{"horas_sem_envio": 2.5, "dias_semana": [1, 2, 3, 4, 5], "hora_inicio": 9, "hora_fim": 18, "novas_para_fechar_manual": 3}'::jsonb,
       descricao = '0197: suspeita automática de biometria da Nio fora do ar — dia útil (dias_semana ISO, sem feriado), entre hora_inicio e hora_fim, com horas_sem_envio inteiras sem biometria nova no GED360; a marcada à mão fecha com X biometrias novas.',
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

commit;
