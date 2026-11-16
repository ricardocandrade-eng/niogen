-- NIOGEN | supabase/migrations/0234_abertura_sou_cliente_e_2030.sql | 16/11/2026 — Claude Code / Opus 5.5
-- Pedido do Ricardo (16/11) sobre o menu de 3 botões da 1ª resposta da Mari (abertura B2, 0070; formato 'botoes' em produção):
--   · "💬 Falar com alguém" → era quase sempre cliente Nio pedindo suporte, e caía no backoffice. Vira "🏠 Sou cliente Nio": a Mari
--     explica que aqui é a central de VENDAS e manda para o App Nio / 0800 (resposta fixa no 5 · Motor, sem time, sem handoff).
--   · "💰 Ver os planos" → não mostrava plano nenhum (sem a cidade, a Mari só mandava um texto genérico). Sai do menu.
--   · Entra o gancho "🔒 Preço até 2030" (preço fixo até janeiro/2030, da tabela vigente) — a resposta pede o CEP.
-- Tudo em config_mari_textos (regra 15): 'abertura_botoes' = chaves na ordem do menu. Os botões antigos seguem reconhecidos
-- (quem tem o menu antigo na tela). Para voltar ao de antes sem deploy: abertura_botoes = 'rua,planos,humano'.
-- Gatilho mari_conversas_abertura_cliente: dados.abertura_botao vira 'cliente' (o toque) → Saída "Já é cliente Nio" pelo
-- encerramento da conversa (quadro_encerrada_motivo 'ja_cliente' → destino ja_cliente_nio): cadência parada, conversa resolvida
-- no Chatwoot com nota, SEM time e sem dono. Se o cliente escrever de novo (ex.: quer Nio em outro endereço), volta para a Mari.
-- Regra 20: (1) destino ja_cliente_nio, sem vez nem prazo (saída) · (2) saída automática: quem escreve de novo volta para a Mari ·
-- (3) estado muda só pelo gatilho, com motivo e autor (turno de sistema) · (4) sem fato novo · (5) já contado no retrato
-- (ja_cliente_nio) e na conferência 17 (saída com dono) — não precisa de item novo.
-- Medição (7 dias): conversas com handoff "Falar com alguém" na abertura → 0; toques em "Sou cliente Nio" e em "Preço até 2030"
-- (mari_turnos.tags ->> 'abertura_botao'); fração das aberturas que dão CEP (era 28/29 no "Ver minha rua").

insert into public.config_mari_textos (chave, texto) values
('abertura_botoes', 'trava2030,rua,cliente'),
('abertura_botao_2030', $t$🔒 Preço até 2030$t$),
('abertura_botao_cliente', $t$🏠 Sou cliente Nio$t$),
('abertura_resp_2030', $t$Isso mesmo! 🔒 Fechando agora, o valor do seu plano fica travado até janeiro de 2030, sem reajuste.

Me manda seu CEP (ou a rua e o bairro) que eu confiro se a fibra chega aí e já te mostro o preço certinho da sua cidade 👇$t$),
('abertura_resp_cliente', $t$Que bom ter você com a gente! 💚

Aqui é a central de vendas da Nio, então não consigo ver sua conta nem resolver suporte por aqui. Pra fatura, 2ª via, suporte técnico ou mudança de plano, o caminho mais rápido é o App Nio ou o 0800 001 1000.

Se quiser levar a Nio pra outro endereço (da família, do trabalho), é comigo: me manda o CEP 😉$t$)
on conflict (chave) do nothing;

create or replace function public._abertura_cliente_depois()
returns trigger language plpgsql security definer set search_path = public as $$
declare g uuid := gen_random_uuid();
begin
  perform public.mari_cadencia_parar(new.id, p_resolvida => true);
  update public.mari_conversas
     set quadro_encerrada_motivo = 'ja_cliente', quadro_encerrada_em = now(), quadro_encerrada_por = null, processando_ate = null
   where id = new.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (new.id, 'sistema', '[Saída "Já é cliente Nio" — o cliente tocou "Sou cliente Nio" na abertura; a Mari mandou para o App Nio / 0800. Se ele escrever de novo, volta para a Mari]', false);
  if coalesce(new.chatwoot_conversation_id, '') <> '' and new.canal = 'whatsapp' and coalesce(new.telefone, '') not like '5500000000%' then
    perform public._bo_enfileirar(g, 1, 'saida', null, new, 'nota', jsonb_build_object('content',
      '⛔ Saída · Já é cliente Nio — o cliente tocou "Sou cliente Nio" na abertura e a Mari indicou o App Nio / 0800 (aqui é só venda). '
      || 'Ninguém precisa responder. Se ele escrever de novo, a Mari responde.'));
    perform public._bo_enfileirar(g, 2, 'saida', null, new, 'resolver', jsonb_build_object('status', 'resolved'));
  end if;
  return null;
end $$;
revoke all on function public._abertura_cliente_depois() from public, anon, authenticated;

drop trigger if exists mari_conversas_abertura_cliente on public.mari_conversas;
create trigger mari_conversas_abertura_cliente after update of dados on public.mari_conversas
  for each row
  when (new.dados ->> 'abertura_botao' = 'cliente' and old.dados ->> 'abertura_botao' is distinct from 'cliente' and new.venda_id is null)
  execute function public._abertura_cliente_depois();
