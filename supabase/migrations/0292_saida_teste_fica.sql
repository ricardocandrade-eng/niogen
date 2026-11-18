-- NIOGEN | supabase/migrations/0292_saida_teste_fica.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11: "Sim, comece pelo conserto do teste" (achado do conserto da conversa nº 91 do Chatwoot).
-- O defeito: a porta aceita a Saída "Teste ou duplicada" (saida:teste_duplicada, andamento/saida_pode_voltar → saida_definitiva),
-- mas na gravação seguinte da linha o _funil_antes devolvia o lead a "em andamento" ("saída dura não vale mais"), porque para ele
-- "teste" só valia com o telefone em config_mari_textos.telefones_teste. A conversa reabria e a cadência voltava (nº 91, 15h43).
-- O que muda: só esse ramo do _funil_antes. A Saída de teste dada pela porta tem saida_motivo = 'teste_duplicada' e passa a ficar,
-- como toda Saída de evento (quem reabre é a porta: Saída definitiva só o admin). O teste da lista de telefones (saida_motivo nulo)
-- e a "instalada" continuam voltando quando a regra dura deixa de valer. Recriada a partir da versão no ar (md5 36b9bf68… = 0290).
-- Regra 20: (1) nada novo — situação Saída definitiva; (2) saída já existe (Reabrir do admin); (3) muda pela porta, com autor;
-- (4) sem fonte nova; (5) sem estado novo — conferência sem mudança. Cenário X28 (vermelho antes). Tela, guia e desempenho: sem impacto.

begin;

CREATE OR REPLACE FUNCTION public._funil_antes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d        jsonb;
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
  -- 0290: handoff e fim da cadência da Mari também saíram daqui — dão a Saída pela porta (_porta_mari_destino). Ficam a Saída dura,
  -- o 0151 e a 1ª conta.
  if d ->> 'duro' is not null then
    novo := d ->> 'duro'; det := d ->> 'duro_det';
  elsif tg_op = 'UPDATE' and ant = 'sem_cobertura' and old.funil_detalhe = 'viabilidade: sem cobertura' then
    novo := coalesce(d ->> 'evento', 'em_andamento');                                  -- 0151: o sem cobertura era a regra dura
    det  := coalesce(d ->> 'evento_det', 'cobertura revista: operador elegível (≤ 200 m)');  -- e ela não vale mais
  elsif tg_op = 'UPDATE' and old.funil_destino is not null
        and (ant = 'instalada' or (ant = 'teste_duplicada' and old.saida_motivo is distinct from 'teste_duplicada')) then
    -- 0292: a Saída "Teste ou duplicada" dada pela porta (saida_motivo = teste_duplicada) não é a regra dura do telefone de teste:
    -- fica, como toda Saída de evento (quem reabre é a porta). Só o teste que veio da lista de telefones volta quando sai dela.
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

commit;
