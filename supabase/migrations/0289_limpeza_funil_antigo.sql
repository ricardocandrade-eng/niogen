-- NIOGEN | supabase/migrations/0289_limpeza_funil_antigo.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Porta, passo seguinte, peça 3 de 3 — apaga a máquina antiga que ficou sem uso depois da 0287/0288 (Ricardo: "Faça esta tarefa aqui").
--  (1) _funil_antes perde os ramos "venda" (funil_evento = 'venda'), "reabrir" (funil_evento = 'reabrir') e "quadro" (quadro_encerrada_motivo
--      mudou fora da porta): ninguém mais os aciona — a venda mudada por fora é da porta (_porta_venda_mudou) e o Quadro/abertura gravam
--      pela porta (sob porta.aplicando, que o _funil_antes já respeita). Ficam: etapa, Saída dura, handoff da Mari, cadência esgotada,
--      0151 (sem cobertura revisto) e a 1ª conta. Recriado da versão no ar (18/11 ~14h25).
--  (2) apaga _funil_venda_mudou e _venda_saida_devolve (os gatilhos saíram na 0288).
-- Fica: _saida_limpa_conversa/_venda — não é ramo morto: limpa os campos da Saída quando o destino muda por outra via (inclusive a porta da
-- venda) e continua necessário.
-- Backup: niogen_backup_181126_1319 (antes das 0287–0289: só funções mudaram depois). Sem CASCADE.
-- Regra 20: só remove código sem uso (1–5 não se aplicam). Tela, guia e desempenho: sem impacto.
begin;

CREATE OR REPLACE FUNCTION public._funil_antes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d        jsonb;
  ev       text;
  novo     text; det text;
  ant      text := coalesce(new.funil_destino, 'em_andamento');
begin
  d := public._funil_calcular(new);
  -- etapa: só sobe
  if new.funil_etapa is null or public._funil_ordem('etapa', d ->> 'etapa') > public._funil_ordem('etapa', new.funil_etapa) then
    new.funil_etapa := d ->> 'etapa';
  end if;
  -- 0265 (passo 5): Saída, Reabrir, silenciar e Não contatar passam pela porta, que grava o destino — o gatilho não decide por cima
  if coalesce(current_setting('porta.aplicando', true), '') = '1' then
    new.funil_evento := null;
    return new;
  end if;

  -- qual fonte de evento acabou de mudar (só ela vale: um sinal velho não derruba uma conversa que o cliente reabriu)
  -- 0289: venda, reabrir e Quadro saíram daqui — a venda mudada por fora é da porta (_porta_venda_mudou, 0288) e o Quadro/abertura
  -- gravam pela porta; aqui ficam a Mari (handoff), a cadência e a Saída dura
  ev := case
    when tg_op = 'UPDATE' and new.handoff_motivo is distinct from old.handoff_motivo and d ->> 'hand' is not null then 'hand'
    when tg_op = 'UPDATE' and new.cadencia_passo is distinct from old.cadencia_passo and d ->> 'cad' is not null then 'cad' end;

  if d ->> 'duro' is not null and (ev is null
      or public._funil_ordem('destino', d ->> 'duro') <= public._funil_ordem('destino', d ->> ev)) then
    novo := d ->> 'duro'; det := d ->> 'duro_det';
  elsif ev is not null then
    novo := d ->> ev; det := d ->> (ev || '_det');
  elsif tg_op = 'UPDATE' and ant = 'sem_cobertura' and old.funil_detalhe = 'viabilidade: sem cobertura' then
    novo := coalesce(d ->> 'evento', 'em_andamento');                                  -- 0151: o sem cobertura era a regra dura
    det  := coalesce(d ->> 'evento_det', 'cobertura revista: operador elegível (≤ 200 m)');  -- e ela não vale mais
  elsif tg_op = 'UPDATE' and old.funil_destino is not null and ant in ('teste_duplicada', 'instalada') then
    novo := 'em_andamento'; det := 'saída dura não vale mais';
  elsif tg_op = 'UPDATE' and old.funil_destino is not null then
    novo := old.funil_destino; det := old.funil_detalhe;                 -- saída fica (quem reabre é a porta)
  else
    novo := coalesce(d ->> 'evento', 'em_andamento'); det := d ->> 'evento_det';   -- 1º cálculo (backfill / conversa nova)
  end if;

  if novo is distinct from new.funil_destino then
    new.funil_destino := novo;
    new.funil_detalhe := det;
    new.funil_destino_em := now();
    if novo = 'em_andamento' then new.chatwoot_resolvida := false; end if;   -- 0155: reabriu → a cadência volta a valer
    if novo <> 'em_andamento' then new.funil_alerta := null; new.funil_alerta_em := null; end if;   -- destino registrado: alerta some
  end if;
  new.funil_evento := null;
  return new;
exception when others then
  -- o funil nunca derruba a gravação da conversa: registra e segue sem recalcular
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (new.id, 'funil_antes', sqlerrm);
  new.funil_evento := null;
  return new;
end;
$function$;

drop function public._funil_venda_mudou();
drop function public._venda_saida_devolve();

commit;
