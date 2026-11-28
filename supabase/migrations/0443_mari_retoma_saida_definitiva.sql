-- NIOGEN | supabase/migrations/0443_mari_retoma_saida_definitiva.sql | 28/11/2026 — Claude Code (Fable 5.2)
-- Caso L-132 (Lígia, #117): Saída definitiva por crédito negado em 16/11. Em 26/11 e 28/11 ela perguntou três vezes se o chip do plano
-- é da TIM. A Mari tem essa resposta na base, mas a 0383 (caso L-82, 24/11) manda a Mari calar em toda Saída definitiva: a cliente
-- ouviu "já chamei o nosso time" e esperou 153 min em 26/11 e 72 min em 28/11. Ricardo, 28/11: "acho que ela poderia retomar a
-- conversa, lendo todo o contexto e seguindo com o atendimento normal novamente e encaminhar para o time quando encerrado a parte
-- dela" → levantamento docs/LEVANTAMENTO_mari_pos_venda_e_voltas_281126_0934.md → "Sim, sem bateria".
-- O que muda:
--  (1) config_regras.mari_retoma_saida = {ligado, motivos}: em quais Saídas definitivas a Mari volta a responder. Começa com
--      credito_negado e reprovado_biometria (venda que não saiu). nio_nao_instalou (o caso L-82), venda_indevida_fraude e
--      teste_duplicada seguem com a 0383. Voltar atrás sem deploy: ligado = false.
--  (2) mari_entrada__nucleo: nesses motivos a fala do cliente NÃO vai para 'cliente_escreveu:ao_time' — segue para a Mari, que
--      recebe o resumo do caso (motor "5b", linha retomada_saida) e tem três travas no código do nó "7 · Extrair" (não promete
--      pedido, não manda [CONDICOES]; o que o cliente afirma sobre o sistema vai ao time). "Ok", "obrigado", "não" soltos
--      continuam em silêncio, como hoje. Pedido de indicação da Saída respondido com telefone (0303) continua como hoje.
--  (3) quando a Mari passa ao time ([HANDOFF]) nessa Saída, mari_handoff__nucleo não faz o handoff comum (time dono + etiqueta num
--      lead em Saída): chama a volta ao time da 0383 — conversa aberta com nota, "já chamei o nosso time" (1 a cada 12 h), aberta
--      até uma pessoa responder (0420). mari_chatwoot_pedir, nessa Saída, só grava a nota com o briefing.
--  (4) nada mais muda: a situação continua "Saída — definitiva" (quem reabre é o time, pela ficha); sem handoff, a varredura de
--      10 min fecha a conversa 5 min depois da última fala nossa.
--  Venda na OS/instalação e "Já tem pedido Nio" continuam com a fala fixa e o time (0383 + 0420).
-- Regra 20: (1) nenhuma situação nova, vez e prazo da Saída; (2) ninguém parado: a Mari responde na hora, e o que ela não resolve
-- vira handoff; sem resposta do cliente a conversa fecha sozinha; (3) nada grava estado fora da porta — só deixa de chamar um
-- evento; (4) fonte: a conversa; (5) sem número novo: a conferência da conversa aberta fora do andamento (0335) é a de sempre.
-- Regras de ouro: 6 (mensagem automática nunca por cima de pessoa — o guard do n8n segue valendo: conversa com agente ou time
-- atribuído não chega à Mari). Cenário X165. Desempenho: 1 leitura de config_regras por mensagem de cliente em Saída definitiva.
-- Medir em 7 dias: voltas em crédito negado/biometria × respondidas pela Mari em < 1 min × handoffs × reabertas em venda; e zero
-- "vou abrir seu pedido" nessas conversas (mari_turnos.violacoes).
begin;

insert into public.config_regras (chave, valor, descricao)
values ('mari_retoma_saida', '{"ligado": true, "motivos": ["credito_negado", "reprovado_biometria"]}'::jsonb,
        '0443 (L-132): Saídas definitivas em que a Mari volta a responder quando o cliente escreve, com o resumo do caso e as travas do nó 7. ligado=false devolve tudo à fala fixa e ao time (0383).')
on conflict (chave) do nothing;

create or replace function public._mari_retoma_saida(c public.mari_conversas) returns boolean
 language sql stable security definer set search_path to 'public' as $f$
  select coalesce((select coalesce((r.valor ->> 'ligado')::boolean, false)
                          and coalesce(c.funil_destino, '') in (select jsonb_array_elements_text(coalesce(r.valor -> 'motivos', '[]'::jsonb)))
                     from public.config_regras r where r.chave = 'mari_retoma_saida'), false)
$f$;
revoke all on function public._mari_retoma_saida(public.mari_conversas) from public, anon, authenticated;
grant execute on function public._mari_retoma_saida(public.mari_conversas) to service_role;

-- a entrada (no __nucleo): Saída definitiva com motivo de retomada não vai ao time — segue para a Mari
do $do$
declare
  d    text := pg_get_functiondef('public.mari_entrada__nucleo'::regproc);
  de   text := $a$if v_s = 'saida_definitiva'$a$;
  para text := $a$if (v_s = 'saida_definitiva' and not (public._mari_retoma_saida(v_conv) and (p_midia is not null or not (public._saida_so_confirmacao(p_texto) or public._norm_resposta(p_texto) in ('confirmo', 'tudo certo') or public._saida_so_negacao(p_texto)))))$a$;
begin
  if position('_mari_retoma_saida' in d) > 0 then return; end if;   -- já aplicada
  if position('_saida_so_negacao' in d) = 0 then raise exception '0443: a 0420 precisa subir antes (falta o _saida_so_negacao na entrada)'; end if;
  if (length(d) - length(replace(d, de, ''))) / length(de) <> 1 then
    raise exception '0443: o teste da Saída definitiva (0383) não está uma vez só na mari_entrada__nucleo';
  end if;
  execute replace(d, de, para);
end $do$;

-- o handoff da Mari dentro dessa Saída (X165, visto vermelho em 28/11: o handoff comum punha time e etiqueta de handoff num lead
-- em Saída — contra as regras S2/S3 — e a conversa fechava sem ninguém responder). Aqui "passar ao time" é o mesmo caminho da
-- 0383/0420: a conversa abre com nota, o cliente recebe "já chamei o nosso time" (1 a cada 12 h), fica aberta até uma pessoa
-- responder (0420) e o alarme diz "é com o TIME". A situação não muda e a conversa segue 'ativo'.
do $do$
declare
  d    text := pg_get_functiondef('public.mari_handoff__nucleo'::regproc);
  de   text := $a$  -- 0266 (C3, Ricardo 17/11):$a$;
  novo text := $a$  -- 0443 (L-132): handoff da Mari numa Saída definitiva em que ela retoma (crédito negado, biometria reprovada) = volta ao time
  if coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada') and public._mari_retoma_saida(c)
     and p_motivo not in ('interesse_caindo', 'multiplos_decisores', 'recusa_compra', 'fora_de_area', 'sem_cobertura', 'sem_contato', 'ja_cliente_nio') then
    update public.mari_conversas
       set handoff_briefing = coalesce(nullif(btrim(l ->> 'briefing'), ''), handoff_briefing), processando_ate = null
     where id = p_conversa;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[a Mari retomou o atendimento nesta Saída e passou ao time (' || coalesce(p_motivo, '-') || ', 0443) — a conversa abre para o time]', false);
    -- a fala da Mari que veio logo antes deixou um "refechar" marcado para daqui a 2 min (_conversa_refechar): o cliente agora espera o time
    update public.chatwoot_acoes set status = 'cancelada'
     where conversa_id = c.id and tipo = 'resolver' and momento = 'refechar' and status = 'pendente';
    perform public.porta('cliente_escreveu:ao_time', c.id, null::uuid, jsonb_build_object('texto', coalesce(l ->> 'briefing', '')));
    return jsonb_build_object('ok', true, 'volta_ao_time', true, 'venda_id', c.venda_id);
  end if;

$a$;
begin
  if position('0443 (L-132)' in d) = 0 then
    if (length(d) - length(replace(d, de, ''))) / length(de) <> 1 then raise exception '0443: mari_handoff__nucleo mudou — a âncora do C3 (0266) não está uma vez só'; end if;
    execute replace(d, de, novo || de);
  end if;
  -- o pedido de etiquetas/time do nó 9e: nessa Saída só a nota com o briefing entra (sem time dono, sem etiqueta de handoff)
  d  := pg_get_functiondef('public.mari_chatwoot_pedir'::regproc);
  de := $a$  if p_pedido in ('handoff_venda', 'handoff_humano', 'handoff_saida') then$a$;
  novo := $a$  if p_pedido in ('handoff_venda', 'handoff_humano', 'handoff_saida')
     and coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada') and public._mari_retoma_saida(c) then
    -- 0443 (L-132): a Mari passou ao time dentro de uma Saída — quem abre a conversa é a volta ao time (0383); aqui só a nota
    if p_nota is not null and public._porta_ordem(g, 2, 'mari_handoff', c, 'nota', jsonb_build_object('content', p_nota)) then
      feito := feito || 'nota'::text; end if;
  elsif p_pedido in ('handoff_venda', 'handoff_humano', 'handoff_saida') then$a$;
  if position('0443 (L-132)' in d) = 0 then
    if (length(d) - length(replace(d, de, ''))) / length(de) <> 1 then raise exception '0443: mari_chatwoot_pedir mudou — o teste do pedido de handoff não está uma vez só'; end if;
    execute replace(d, de, novo);
  end if;
end $do$;

update public.config_transicao
   set nota = 'crédito negado e biometria reprovada: a Mari responde com o resumo do caso e passa ao time no fim (0443); demais motivos: fala fixa e a conversa abre para o time (0383, cliente_escreveu:ao_time)'
 where evento = 'cliente_escreveu' and de = 'saida_definitiva';
update public.config_situacao
   set mari = 'crédito negado e biometria reprovada: responde com o resumo do caso, sem prometer pedido, e passa ao time (0443); demais: fala fixa e o time (0383)'
 where codigo = 'saida_definitiva';

do $do$
begin
  if position('_mari_retoma_saida' in pg_get_functiondef('public.mari_entrada__nucleo'::regproc)) = 0 then
    raise exception '0443: o remendo da entrada não entrou';
  end if;
  if not exists (select 1 from public.config_regras where chave = 'mari_retoma_saida') then raise exception '0443: config ausente'; end if;
  if position('0443 (L-132)' in pg_get_functiondef('public.mari_handoff__nucleo'::regproc)) = 0
     or position('0443 (L-132)' in pg_get_functiondef('public.mari_chatwoot_pedir'::regproc)) = 0 then
    raise exception '0443: o remendo do handoff não entrou';
  end if;
end $do$;

commit;
