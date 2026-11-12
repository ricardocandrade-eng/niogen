-- NIOGEN | supabase/migrations/0128_balanco_todos_e_aviso.sql | 11/11/2026 — Claude Code
-- Ricardo, 11/11 ~22h45: o balanço das conversas paradas sai do Painel e vira um botão flutuante (em todas as telas) que abre num
-- modal, "visível para todos os usuários". Aqui: a leitura de balanco_diario passa de admin/backoffice para qualquer usuário
-- logado com perfil (vendedor inclusive) — o conteúdo é o resumo e as respostas sugeridas, sem CPF nem telefone. O aviso das 8h
-- (resumo_diario_whatsapp) troca "no Painel" por "no NIOGEN (botão Balanço)".

drop policy if exists balanco_diario_ler on public.balanco_diario;
create policy balanco_diario_ler on public.balanco_diario for select to authenticated
  using ((select public.meu_perfil()) is not null);

CREATE OR REPLACE FUNCTION public.resumo_diario_whatsapp(p_dia date DEFAULT (((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date - 1))
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r jsonb; d jsonb; v jsonb; m jsonb; pa jsonb; pz jsonb; e jsonb; ri jsonb;
  dows text[] := array['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb'];
  p text[];
  brl text;
  prazos text;
begin
  if auth.role() is distinct from 'service_role' and auth.uid() is not null and public.meu_perfil() is distinct from 'admin' then
    raise exception 'resumo_diario_whatsapp: só admin' using errcode = '42501';
  end if;
  r := public.resumo_diario(p_dia);
  d := r->'dados'; v := d->'vendas'; m := d->'meta_ads'; pa := d->'paradas'; pz := d->'prazos'; e := d->'em_espera'; ri := d->'ritmo';
  brl := replace(to_char((m->>'gasto')::numeric, 'FM999990.00'), '.', ',');
  prazos := case when (pz->'agendar'->>'vencidos')::int + (pz->'agendar'->>'hoje')::int + (pz->'agendar'->>'amanha')::int
                    + (pz->'docs'->>'vencidos')::int + (pz->'docs'->>'hoje')::int + (pz->'docs'->>'amanha')::int = 0
                 then 'nada vencendo hoje nem amanhã'
                 else format('agendar: %s vencido(s), %s hoje, %s amanhã · docs: %s vencido(s), %s hoje, %s amanhã',
                             pz->'agendar'->>'vencidos', pz->'agendar'->>'hoje', pz->'agendar'->>'amanha',
                             pz->'docs'->>'vencidos', pz->'docs'->>'hoje', pz->'docs'->>'amanha') end
            || case when (e->>'abertas')::int > 0 then format(' · em espera: %s (%s para revisar)', e->>'abertas', e->>'revisar_hoje_ou_antes') else '' end;
  p := array[
    format('%s %s', dows[extract(dow from p_dia)::int + 1], to_char(p_dia, 'DD/MM')),
    format('%s nova(s) · %s qualificada(s) pela Mari · %s pedido(s) · %s biometria(s) · %s instalada(s)',
           v->>'criadas', v->>'qualificadas_mari', v->>'pedidos', v->>'biometrias', v->>'instaladas'),
    case when (m->>'conversas')::int > 0
         then format('R$ %s · %s conversa(s) · R$ %s por conversa', brl, m->>'conversas',
                     replace(to_char((m->>'custo_por_conversa')::numeric, 'FM999990.00'), '.', ','))
         else format('R$ %s · nenhuma conversa', brl) end,
    format('%s com humano sem resposta · %s cliente esperando a Mari (há mais de %s h)', pa->>'com_humano', pa->>'cliente_sem_resposta',
           replace(pa->>'horas', '.', ','))
      || coalesce((select format(' · balanço: %s com resposta sugerida no NIOGEN (botão Balanço)', jsonb_array_length(bd.itens))
                     from public.balanco_diario bd
                    where bd.dia = (now() at time zone 'America/Sao_Paulo')::date and bd.erro is null
                      and jsonb_array_length(bd.itens) > 0
                    order by bd.criado_em desc limit 1), ''),
    prazos,
    case when ri is null or (ri->>'meta')::int = 0 then 'sem meta cadastrada'
         when (ri->>'faltam')::int = 0 then format('%s/%s instaladas · meta batida', ri->>'instaladas', ri->>'meta')
         else format('%s/%s instaladas · faltam %s em %s dias · %s por dia', ri->>'instaladas', ri->>'meta', ri->>'faltam',
                     ri->>'dias_restantes', replace(ri->>'por_dia', '.', ',')) end
  ];
  return jsonb_build_object(
    'template', 'resumo_diario_interno', 'idioma', 'pt_BR',
    'destino', (select valor #>> '{}' from public.config_regras where chave = 'resumo_destino_whatsapp'),
    'params', to_jsonb(p),
    'texto', r->>'texto');
end $function$;
