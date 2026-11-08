-- NIOGEN | supabase/migrations/0063_mari_zerar_apaga_venda_teste.sql | 08/11/2026 01h00 — Claude Code (pedido do Ricardo)
-- Por quê: no teste de 08/11 00h37 a venda não nasceu ("⚠️ VENDA NÃO CRIADA — duplicidade") porque o #zerar (0062) não apagava
-- a venda do teste anterior (mesmo CPF e endereço). Ricardo: "'zerar' deve sim apagar a venda também".
-- O quê: mari_zerar_memoria, além de encerrar a conversa da Mari, APAGA as vendas que nasceram de conversas da Mari desse
-- número de teste (config_mari_textos.telefones_teste) — qualquer ciclo, inclusive os já encerrados. Trava: venda com nº de
-- pedido da Nio, pontos lançados ou pagamento de parceiro NÃO é apagada (fica e é contada em vendas_mantidas).
-- Eventos, contatos e adicionais da venda caem junto (ON DELETE CASCADE); mari_conversas.venda_id e nio_viab_log ficam nulos
-- (SET NULL). Os turnos da conversa continuam guardados.

create or replace function public.mari_zerar_memoria(p_telefone text, p_chatwoot_conversation_id text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_tel      text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_lista    text[];
  v_ids      uuid[];
  v_apagadas int := 0;
  v_mantidas int := 0;
begin
  select array_remove(regexp_split_to_array(regexp_replace(coalesce(texto, ''), '[^0-9,]', '', 'g'), ','), '')
    into v_lista from public.config_mari_textos where chave = 'telefones_teste';
  if v_tel !~ '^\d{10,15}$' or v_lista is null or not (v_tel = any (v_lista)) then
    return jsonb_build_object('ok', false, 'motivo', 'numero fora de telefones_teste');
  end if;

  with fechadas as (
    update public.mari_conversas
       set status = 'encerrado_humano', processando_ate = null
     where telefone = v_tel and canal = 'whatsapp' and status in ('ativo', 'handoff_realizado')
    returning id)
  select array_agg(id) into v_ids from fechadas;

  update public.mari_turnos set pendente = false where conversa_id = any (coalesce(v_ids, '{}')) and pendente;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  select id, 'sistema', '[memória da Mari zerada pelo comando #zerar (teste) — conversa ' || coalesce(p_chatwoot_conversation_id, '?')
         || ' do Chatwoot; a próxima mensagem abre uma conversa nova; vendas de teste apagadas]', false
    from unnest(coalesce(v_ids, '{}')) as id;

  -- 0063: vendas que nasceram de conversas da Mari deste número de teste (todos os ciclos).
  with alvo as (
    select distinct v.id,
           (coalesce(btrim(v.nio_pedido), '') = ''
            and not exists (select 1 from public.pontos_lancamentos p where p.venda_id = v.id)
            and not exists (select 1 from public.parceiro_pagamentos p where p.venda_id = v.id)) as pode
      from public.vendas v
      join public.mari_conversas c on c.telefone = v_tel and c.canal = 'whatsapp'
                                  and (c.venda_id = v.id or v.origem_ref = 'mari:' || c.id)),
  apagadas as (
    delete from public.vendas v using alvo a where a.id = v.id and a.pode returning 1)
  select (select count(*) from apagadas), (select count(*) from alvo where not pode) into v_apagadas, v_mantidas;

  return jsonb_build_object('ok', true, 'conversas_encerradas', coalesce(cardinality(v_ids), 0),
                            'vendas_apagadas', v_apagadas, 'vendas_mantidas', v_mantidas);
end;
$$;
comment on function public.mari_zerar_memoria(text, text) is
  'Comando #zerar (0062/0063): encerra a conversa da Mari de um número de teste (config_mari_textos.telefones_teste) e apaga as vendas de teste dele (nunca com nº de pedido, pontos ou pagamento de parceiro); a próxima mensagem começa do zero.';
revoke execute on function public.mari_zerar_memoria(text, text) from public, anon, authenticated;
grant execute on function public.mari_zerar_memoria(text, text) to service_role;
