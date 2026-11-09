-- NIOGEN | supabase/migrations/0080_resumo_diario_whatsapp.sql | 09/11/2026 — Claude Code (decisão do Ricardo, 09/11 manhã: "Pode ser template de WhatsApp")
-- Por quê: o resumo diário (0077) estava pronto com o envio desligado esperando o canal. Canal escolhido: template de utilidade do
--          WhatsApp, sem marca, saindo do número da WABA Nio para o celular do Ricardo (é a opção A do alarme da Mari, Parte 2).
-- O quê (só aditivo):
--   1. config_templates_waba: linha `resumo_diario_interno` (UTILITY, pt_BR, sem marca Nio — uso interno, não vai a cliente).
--      Variável não pode ter quebra de linha no WhatsApp, então o texto vira 6 campos fixos.
--   2. config_regras.resumo_destino_whatsapp: copiado do 1º número de config_mari_textos.telefones_teste (o celular do Ricardo,
--      o mesmo que recebe o aviso do #zerar) — o número não fica escrito no repo.
--   3. resumo_diario_whatsapp(p_dia) → {template, idioma, destino, params[6]} a partir de resumo_diario(p_dia). Só service_role/admin.

insert into public.config_templates_waba (nome, categoria, idioma, corpo, uso)
values ('resumo_diario_interno', 'UTILITY', 'pt_BR',
        E'Resumo do dia {{1}}\n\nVendas: {{2}}\nMeta Ads: {{3}}\nParadas: {{4}}\nPrazos: {{5}}\nMeta do mês: {{6}}\n\nDetalhes no Painel.',
        'Resumo diário às 8h para o Ricardo (n8n resumo_diario). Interno: nunca para cliente.')
on conflict do nothing;

insert into public.config_regras (chave, valor, descricao)
select 'resumo_destino_whatsapp',
       to_jsonb(split_part(regexp_replace(coalesce(texto, ''), '[^0-9,]', '', 'g'), ',', 1)),
       'Resumo diário: número (55 + DDD + número) que recebe o template resumo_diario_interno — o celular do Ricardo'
  from public.config_mari_textos where chave = 'telefones_teste'
on conflict (chave) do nothing;

create or replace function public.resumo_diario_whatsapp(p_dia date default ((now() at time zone 'America/Sao_Paulo')::date - 1))
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
           replace(pa->>'horas', '.', ',')),
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
end $$;
revoke all on function public.resumo_diario_whatsapp(date) from public, anon;
grant execute on function public.resumo_diario_whatsapp(date) to authenticated, service_role;
