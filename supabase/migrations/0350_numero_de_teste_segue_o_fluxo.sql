-- NIOGEN | supabase/migrations/0350_numero_de_teste_segue_o_fluxo.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (21/11 ~22h30, teste real do celular L-236 até o handoff → "Sim, limpa" → "Sim, prepara"): o telefone de
-- teste não conseguia testar o fluxo de venda, por duas razões que não acontecem com cliente de verdade.
--  (1) Todo telefone de teste fica no destino teste_duplicada (0147/0151, para ficar fora das contas). O gatilho mari_turnos_refechar
--      (_conversa_refechar, 0249) trata qualquer destino fora de em_andamento/instalada como Saída e resolve a conversa no Chatwoot a
--      cada fala da Mari. No teste, às 22h07m52s, resolveu logo depois do handoff e o ciclo da Mari encerrou.
--      Agora: com telefone de teste, só resolve de novo quando a venda está em Saída — igual a um cliente de verdade nesse ponto.
--      (_saidas_fechar já deixava a teste_duplicada de fora.) A Saída "Teste ou duplicada" dada pelo time a um telefone que NÃO é
--      de teste (0291/0292, X28) continua resolvendo de novo, como hoje.
--  (2) Cada #zerar encerra a conversa e a próxima fala cria outra linha com o MESMO Chatwoot (#1). Sobraram 15 linhas no #1; no
--      handoff o espelho deu o time a todas e _conversas_volta_mari devolveu 14 delas à Mari (56 ordens no #1: tirou o time e a
--      etiqueta handoff-venda, 14 notas iguais). Limpeza feita à mão em 21/11 ~22h20 (Diário).
--      Agora: quando uma linha de telefone de teste ganha um Chatwoot, as linhas ENCERRADAS do mesmo telefone de teste nesse mesmo
--      Chatwoot são desligadas dele (chatwoot_conversation_id = null). O histórico fica; só deixam de receber o espelho.
-- Só telefone de teste: cliente de verdade não muda em nada. Regra 20: (1) nenhuma situação nova; (2) nenhum estado novo; (3) quem
-- grava o Chatwoot continua sendo a fila; (4) a lista de telefones de teste é a mesma do _funil_antes (função nova, um lugar só);
-- (5) cenário X76.
begin;

do $$
begin
  if md5(pg_get_functiondef('public._conversa_refechar()'::regprocedure)) <> '8064391a4ec4c46a5ab6de25585d83f2' then
    raise exception '0350: _conversa_refechar mudou desde 21/11 (md5) — refazer a migration a partir da versão no ar';
  end if;
end $$;

-- o mesmo critério de "teste" do _funil_antes (0151): canal teste, 5500000000…, ou telefone na lista telefones_teste
create or replace function public._telefone_de_teste(p_telefone text, p_canal text default null)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(p_canal, '') = 'teste' or coalesce(p_telefone, '') like '5500000000%'
      or coalesce(p_telefone, '') = any (coalesce((select array_remove(regexp_split_to_array(
           regexp_replace(coalesce(t.texto, ''), '[^0-9,]', '', 'g'), ','), '')
           from public.config_mari_textos t where t.chave = 'telefones_teste'), '{}'::text[]))
$$;
revoke all on function public._telefone_de_teste(text, text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public._conversa_refechar()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.mari_conversas;
begin
  select * into c from public.mari_conversas where id = new.conversa_id;
  if c.id is null or c.canal <> 'whatsapp' or c.chatwoot_conversation_id is null then return null; end if;
  -- silenciada: o cliente escreveu e o Chatwoot reabriu → adia de novo (não volta para o Live; fica em Conversas › Todas)
  if new.papel = 'lead' and coalesce(c.quadro_encerrada_motivo, '') = 'suporte_nio' then
    if not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver'
                    and a.status in ('pendente', 'executando') and a.payload ->> 'status' = 'snoozed') then
      perform public._bo_enfileirar(gen_random_uuid(), 1, 'silenciar', null, c, 'resolver', jsonb_build_object('status', 'snoozed'),
                                    now() + interval '1 minute');
    end if;
    return null;
  end if;
  -- Saída (fora instalada, que tem o pós-venda) e nós respondemos: resolve de novo
  if new.papel in ('mari', 'humano')
     and coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada')
     and coalesce(c.quadro_encerrada_motivo, '') <> 'suporte_nio'
     -- 0249: não olha o chatwoot_status do espelho — o aviso de reabertura do Chatwoot pode chegar DEPOIS da nossa resposta
     -- (caso Carlos Alberto, 16/11 21h20: resolvida 21h19, cliente escreveu, Mari respondeu, espelho ainda "resolved" → ficou aberta)
     and c.chatwoot_agente is null and not coalesce(c.humano_atribuido, false)
     and (c.venda_id is null or exists (select 1 from public.vendas v where v.id = c.venda_id and v.status = 'saida'))
     -- 0350: telefone de teste fica sempre em teste_duplicada (fora das contas) — isso não é Saída; só a venda em Saída fecha
     and (not (c.funil_destino = 'teste_duplicada' and public._telefone_de_teste(c.telefone, c.canal))
          or exists (select 1 from public.vendas v where v.id = c.venda_id and v.status = 'saida'))
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver'
                      and a.status in ('pendente', 'executando')) then
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'refechar', c.venda_id, c, 'resolver', jsonb_build_object('status', 'resolved'),
                                  now() + interval '2 minutes');
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_conversa_refechar', sqlerrm);
  return null;
end;
$function$;

-- (2) telefone de teste com Chatwoot: as linhas encerradas do mesmo telefone no mesmo Chatwoot deixam de apontar para ele
create or replace function public._teste_desliga_conversas_antigas()
returns trigger language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public._telefone_de_teste(new.telefone, new.canal) then return null; end if;
  update public.mari_conversas m set chatwoot_conversation_id = null
   where m.chatwoot_conversation_id = new.chatwoot_conversation_id and m.id <> new.id and m.canal = new.canal
     and m.telefone = new.telefone and m.status <> 'ativo';
  get diagnostics n = row_count;
  if n > 0 then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (new.id, 'sistema', '[telefone de teste: ' || n || ' conversa(s) antiga(s) deste número desligada(s) do Chatwoot '
            || new.chatwoot_conversation_id || ' (0350)]', false);
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_teste_desliga_conversas_antigas', sqlerrm);
  return null;
end $$;
revoke all on function public._teste_desliga_conversas_antigas() from public, anon, authenticated;

drop trigger if exists mari_conversas_teste_desliga_antigas on public.mari_conversas;
create trigger mari_conversas_teste_desliga_antigas
  after insert or update of chatwoot_conversation_id on public.mari_conversas
  for each row when (new.chatwoot_conversation_id is not null and new.status = 'ativo')
  execute function public._teste_desliga_conversas_antigas();

commit;
