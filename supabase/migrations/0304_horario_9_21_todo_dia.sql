-- NIOGEN | supabase/migrations/0304_horario_9_21_todo_dia.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (18/11 ~22h40, o D3 da Retomada de um lead saiu às 22h): "Horário do contrato: 9–21 seg–dom" ·
-- "Fila Vero e o horário do time passam a seguir o mesmo 9h às 21h todos os dias. Pode aplicar".
-- 1. Toques automáticos da Mari (cadência, Retomada, véspera, cartão, indicação, fila do NIOGEN): de 06–24 (0214) para 09–21,
--    todo dia. Continua valendo também em feriado, como a 0214 decidiu (só a hora muda).
-- 2. Fila Vero: 09–21 todo dia; domingo passa a disparar (chave "domingo" no fila_vero_horario). Feriado continua parado.
-- 3. Horário do time: time_horario 09–21 nos 7 dias, e mari_janela_dia (prazo do consultor, minutos úteis, conferência do
--    parceiro) passa a LER o time_horario — antes tinha sáb 10–16 e domingo fechado escritos no código. Feriado continua fora.
-- Funções recriadas a partir da versão no ar (lição da 0279). Cenário no portão: X38.
begin;

update public.config_regras
   set valor = '{"abre": "09:00", "fecha": "21:00", "todos_os_dias": true}'::jsonb,
       descricao = 'Horário dos toques automáticos da Mari e das mensagens da fila (hora de Brasília). todos_os_dias=true: todo dia, domingo e feriado inclusive, entre abre e fecha (Ricardo, 18/11/2026: "Horário do contrato: 9–21 seg–dom"). false = horário do time (mari_janela_dia).'
 where chave = 'mari_horario_toques';

update public.config_regras
   set valor = '{"semana": ["09:00", "21:00"], "sabado": ["09:00", "21:00"], "domingo": ["09:00", "21:00"]}'::jsonb
 where chave = 'fila_vero_horario';

update public.config_regras
   set valor = '{"1": [9, 21], "2": [9, 21], "3": [9, 21], "4": [9, 21], "5": [9, 21], "6": [9, 21], "7": [9, 21]}'::jsonb
 where chave = 'time_horario';

-- Fila Vero: domingo lê a chave "domingo" (sem ela, domingo segue parado, como antes)
create or replace function public.fila_vero_dentro_horario(p_agora timestamp with time zone default now())
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with t as (select (p_agora at time zone 'America/Sao_Paulo') l),
       h as (select coalesce((select valor from public.config_regras where chave = 'fila_vero_horario'), '{}'::jsonb) v)
  select case
           when exists (select 1 from public.config_feriados f, t where f.data = t.l::date) then false
           when extract(isodow from t.l) = 7 then h.v ? 'domingo'
                and t.l::time >= (h.v #>> '{domingo,0}')::time and t.l::time < (h.v #>> '{domingo,1}')::time
           when extract(isodow from t.l) = 6 then t.l::time >= coalesce((h.v #>> '{sabado,0}')::time, '10:00') and t.l::time < coalesce((h.v #>> '{sabado,1}')::time, '16:00')
           else t.l::time >= coalesce((h.v #>> '{semana,0}')::time, '09:00') and t.l::time < coalesce((h.v #>> '{semana,1}')::time, '21:00')
         end
    from t, h;
$function$;

-- Horário do time: uma fonte só (time_horario). Feriado (nacional, MG, municipal) continua fechado, como em mari_dia_permitido.
create or replace function public.mari_janela_dia(p_dia date, p_cidade text default null::text, out abre timestamp without time zone, out fecha timestamp without time zone)
 returns record
 language sql
 stable
 set search_path to 'public'
as $function$
  select case when f.ok and h.faixa is not null then p_dia + make_interval(hours => (h.faixa ->> 0)::int) end,
         case when f.ok and h.faixa is not null then p_dia + make_interval(hours => (h.faixa ->> 1)::int) end
    from (select public._bo_cfg('time_horario', '{"1": [9, 21], "2": [9, 21], "3": [9, 21], "4": [9, 21], "5": [9, 21], "6": [10, 16]}'::jsonb)
                   -> (extract(isodow from p_dia)::int)::text as faixa) h,
         (select not exists (select 1 from public.config_feriados fe
                              where fe.data = p_dia
                                and (fe.escopo = 'nacional'
                                     or (fe.escopo = 'estadual' and upper(coalesce(nullif(fe.uf, ''), 'MG')) = 'MG')
                                     or (fe.escopo = 'municipal' and lower(fe.cidade) = lower(btrim(coalesce(p_cidade, '')))))) as ok) f
$function$;

commit;
