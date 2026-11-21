-- NIOGEN | supabase/migrations/0344_conversa_segue_venda_em_saida.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- PREPARADA, NÃO APLICADA — espera o OK do Ricardo (mexe no Chatwoot de 1 cliente: fecha a conversa e tira o dono).
-- 21/11 ~08h30: o caso único do ar foi resolvido à mão (Ricardo deu Saída pela ficha); rodar agora não acharia nada.
-- Achado do debate da Live (21/11 ~02h): 1 lead com a venda em Saída · "Nio não instalou" desde 13/11 e a conversa ainda
-- "em andamento", aberta no Chatwoot (de antes da porta: o vendas_porta, que leva a conversa junto quando a venda sai, é da 0263+).
-- A situação gravada diz "Instalação — aguardando" com a vez do cliente, e a Live mostrava "Saída" (S5: conversa e venda dizem a
-- mesma coisa). Conferido no ar: é o único caso (conversa em andamento com a venda em Saída).
-- O que faz: _porta_conversa_segue_venda faz na conversa o que o _porta_venda_mudou faz quando uma venda sai — destino pela regra
-- do funil (_funil_calcular: a Saída da venda; a Saída "dura" vence), sem dono (_porta_soltar), nota e projeção no Chatwoot pela
-- fila (_porta_projetar), anotação na porta. Depois roda uma vez para os casos de hoje.
-- Regra 20: (1) sem estado novo; (2) destino só pela regra da porta, com anotação; dono e Chatwoot pela fila; (3) tela: nada;
--     (4) sem fonte nova; (5) uma vez. Cenário X69.
begin;

create or replace function public._porta_conversa_segue_venda(p_conversa uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.mari_conversas; v public.vendas; d jsonb; alvo text; det text; antes text; ant_dest text;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  select * into v from public.vendas where id = c.venda_id;
  if v.id is null or v.status <> 'saida' or coalesce(c.funil_destino, 'em_andamento') <> 'em_andamento' then
    return jsonb_build_object('ok', false, 'resumo', 'nada a fazer (a venda não está em Saída ou a conversa já saiu)');
  end if;
  d := public._funil_calcular(c);
  alvo := d ->> 'venda'; det := d ->> 'venda_det';
  if d ->> 'duro' is not null and (alvo is null or public._funil_ordem('destino', d ->> 'duro') <= public._funil_ordem('destino', alvo)) then
    alvo := d ->> 'duro'; det := d ->> 'duro_det';
  end if;
  if alvo is null or alvo = 'em_andamento' then
    return jsonb_build_object('ok', false, 'resumo', 'a regra do funil não deu destino de Saída: ' || coalesce(d::text, '?'));
  end if;
  ant_dest := coalesce(c.funil_destino, 'em_andamento');
  antes := public._porta_situacao(c.id, null::uuid);
  perform set_config('porta.aplicando', '1', true);
  update public.mari_conversas
     set funil_evento = null, funil_destino = alvo, funil_detalhe = det, funil_destino_em = now(), funil_alerta = null, funil_alerta_em = null
   where id = c.id;
  perform set_config('porta.aplicando', '', true);
  perform public._porta_soltar(c.id, 'venda em Saída (' || coalesce(v.motivo_saida, 'sem motivo') || ')');
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[venda em Saída — ' || coalesce(v.motivo_saida, 'sem motivo') || ' — a conversa seguiu a venda (0344), vez de ninguém, sem dono]', false);
  perform public._porta_projetar(c.id, 'saida_devolver',
    '↩ Venda em Saída (' || coalesce(v.motivo_saida, 'sem motivo') || ') — a conversa seguiu a venda; sem dono. Se o cliente escrever, a Mari responde.',
    'resolved');
  perform public._porta_anotar('funil:' || alvo, '0344', c.id, v.id, antes,
    jsonb_build_object('ok', true, 'resumo', ant_dest || ' → ' || alvo || coalesce(' (' || det || ')', '') || ' · a conversa seguiu a venda'));
  return jsonb_build_object('ok', true, 'resumo', ant_dest || ' → ' || alvo);
end $$;
revoke all on function public._porta_conversa_segue_venda(uuid) from public, anon, authenticated;

-- os casos de hoje (1 no ar em 21/11)
select public._porta_conversa_segue_venda(m.id)
  from public.mari_conversas m join public.vendas v on v.id = m.venda_id
 where v.status = 'saida' and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento' and m.canal = 'whatsapp';

commit;
