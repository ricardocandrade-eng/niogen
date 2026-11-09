-- NIOGEN | supabase/migrations/0088_funil_mes_sem_teste.sql | 09/11/2026 — Claude Code
-- Prova da 0087: a venda de teste do Ricardo aparecia em "Agendadas". O funil do mês ignora os telefones de teste
-- (config_mari_textos.telefones_teste), nas conversas e nas vendas (pelo telefone da venda ou da conversa ligada — o WhatsApp
-- grava sem o 9º dígito).

create or replace function public.funil_mes(p_mes date default (now() at time zone 'America/Sao_Paulo')::date)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  tz  text := 'America/Sao_Paulo';
  ini timestamptz := (date_trunc('month', p_mes)::timestamp) at time zone 'America/Sao_Paulo';
  fim timestamptz := ((date_trunc('month', p_mes) + interval '1 month')::timestamp) at time zone 'America/Sao_Paulo';
  r   jsonb;
  teste text[];
begin
  if public.meu_perfil() is null then raise exception 'Sem acesso.' using errcode = '42501'; end if;
  -- 0088: telefones de teste (config_mari_textos.telefones_teste, a lista da Mari) ficam fora do funil.
  select coalesce(array_agg(public.tel_norm(x)), '{}') into teste
    from unnest(regexp_split_to_array((select coalesce(texto, '') from public.config_mari_textos where chave = 'telefones_teste'), '[^0-9]+')) x
   where x <> '';
  select jsonb_build_object(
    'mes', to_char(p_mes, 'YYYY-MM'),
    'etapas', jsonb_build_array(
      jsonb_build_object('id', 'leads', 'nome', 'Leads', 'dica', 'Conversas novas com a Mari no WhatsApp (sem testes)',
        'n', (select count(*) from public.mari_conversas c where c.canal = 'whatsapp' and c.telefone not like '5500000000%' and not (public.tel_norm(c.telefone) = any (teste))
               and c.created_at >= ini and c.created_at < fim)),
      jsonb_build_object('id', 'qualificados', 'nome', 'Qualificados', 'dica', 'Leads com os dados completos (a Mari passou ou o time cadastrou) — ainda NÃO é venda',
        'n', (select count(*) from public.vendas v where not (coalesce(public.tel_norm(v.cliente_whatsapp), '') = any (teste)) and not exists (select 1 from public.mari_conversas mt where mt.venda_id = v.id and public.tel_norm(mt.telefone) = any (teste)) and v.criado_em >= ini and v.criado_em < fim)),
      jsonb_build_object('id', 'viabilidade', 'nome', 'Viabilidade ok', 'dica', 'Portal PAP etapa 2 respondeu Viável',
        'n', (select count(*) from public.vendas v where not (coalesce(public.tel_norm(v.cliente_whatsapp), '') = any (teste)) and not exists (select 1 from public.mari_conversas mt where mt.venda_id = v.id and public.tel_norm(mt.telefone) = any (teste)) and v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= ini and v.nio_viab_em < fim)),
      jsonb_build_object('id', 'vendas', 'nome', 'Vendas (OS)', 'dica', 'VENDA = OS aberta no portal (etapa 7): nº do pedido + nº da OS',
        'n', (select count(*) from public.vendas v where not (coalesce(public.tel_norm(v.cliente_whatsapp), '') = any (teste)) and not exists (select 1 from public.mari_conversas mt where mt.venda_id = v.id and public.tel_norm(mt.telefone) = any (teste)) and v.vendido_em >= ini and v.vendido_em < fim and coalesce(v.nio_os, '') <> '')),
      jsonb_build_object('id', 'biometria', 'nome', 'Biometria ok', 'dica', 'Biometria validada pela Nio (link automático depois da OS)',
        'n', (select count(*) from public.vendas v where not (coalesce(public.tel_norm(v.cliente_whatsapp), '') = any (teste)) and not exists (select 1 from public.mari_conversas mt where mt.venda_id = v.id and public.tel_norm(mt.telefone) = any (teste)) and v.biometria_validada_em >= ini and v.biometria_validada_em < fim and coalesce(v.nio_os, '') <> '')),
      jsonb_build_object('id', 'agendadas', 'nome', 'Agendadas', 'dica', 'Instalação agendada com o cliente',
        'n', (select count(*) from public.vendas v where not (coalesce(public.tel_norm(v.cliente_whatsapp), '') = any (teste)) and not exists (select 1 from public.mari_conversas mt where mt.venda_id = v.id and public.tel_norm(mt.telefone) = any (teste)) and v.agendamento_registrado_em >= ini and v.agendamento_registrado_em < fim)),
      jsonb_build_object('id', 'instaladas', 'nome', 'Instaladas', 'dica', 'Instalação concluída (OSAB) — é o que paga comissão e conta na meta',
        'n', (select count(*) from public.vendas v where not (coalesce(public.tel_norm(v.cliente_whatsapp), '') = any (teste)) and not exists (select 1 from public.mari_conversas mt where mt.venda_id = v.id and public.tel_norm(mt.telefone) = any (teste)) and v.instalado_em >= ini and v.instalado_em < fim and v.status <> 'saida')),
      jsonb_build_object('id', 'ativas', 'nome', 'Ativas', 'dica', 'Serviço ativado',
        'n', (select count(*) from public.vendas v where not (coalesce(public.tel_norm(v.cliente_whatsapp), '') = any (teste)) and not exists (select 1 from public.mari_conversas mt where mt.venda_id = v.id and public.tel_norm(mt.telefone) = any (teste)) and v.ativado_em >= ini and v.ativado_em < fim and v.status <> 'saida'))
    )) into r;
  return r;
end;
$function$;
revoke all on function public.funil_mes(date) from public, anon;
grant execute on function public.funil_mes(date) to authenticated;
