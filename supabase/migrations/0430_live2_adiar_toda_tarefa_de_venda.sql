-- NIOGEN | supabase/migrations/0430_live2_adiar_toda_tarefa_de_venda.sql | 27/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 27/11, caso L-199: "O cliente só se mudará no dia 18 e a agenda da Nio só permite agendar até o dia 04. Chegando no
-- dia 04, eu vou postergando o agendamento até abrir agenda no dia 18. O cliente está ciente disso. Eu entendo que agora só
-- preciso retirar ele da Live, com um lembrete para voltar no dia 04" → "Mesmo marcando Nada a responder e colocando o lembrete,
-- ele continua na Live 2.0".
-- O cartão dele é "Cliente pediu para remarcar a instalação" (tipo Agendar). Esse tipo não tinha Adiar: o botão só existia em
-- cobrança e em Decidir, e as outras tarefas de venda mandavam adiar pela Pendência da ficha. O mesmo vale para o L-82
-- (Pendência Nio "revisar hoje").
-- O que muda: live2_fila() passa a oferecer o Adiar (live2_baixa, com data — teto de 30 dias da 0429) em TODA tarefa de venda que
-- não seja "Responder". A fila já escondia qualquer tarefa que não é "Responder" com baixa em vigor; faltava só o botão.
-- Continua valendo: a tarefa volta sozinha na data, volta na hora se o cliente escrever, e "Responder" e venda em risco nunca
-- são adiados.
-- Regra 20: (1) etapa, situação, vez e prazo não mudam; (2) ninguém parado em silêncio: todo Adiar tem data de volta e teto;
-- (3) nenhum estado novo — é a live2_baixa de sempre; (4) fonte única: live2_baixas; (5) conferência: sem item novo.
-- Regras de ouro 2 e 10: nenhum evento novo na porta. live2_fila é remendada da versão no ar. Cenário X152.
begin;

do $mig$
declare
  d text := pg_get_functiondef('public.live2_fila()'::regprocedure);
begin
  if position('0430' in d) > 0 then
    raise notice '0430: live2_fila já oferece o Adiar em toda tarefa de venda';
    return;
  end if;
  if regexp_count(d, E'\\(\\(l\\.cobranca or l\\.tipo = ''decidir''\\) and \\(l\\.conversa_id is not null or l\\.venda_id is not null\\)') <> 1 then
    raise exception '0430: não achei o ponto de encaixe em live2_fila';
  end if;
  d := replace(d, $a$((l.cobranca or l.tipo = 'decidir') and (l.conversa_id is not null or l.venda_id is not null)$a$,
                  $b$((l.cobranca or l.tipo = 'decidir' or (l.venda_id is not null and l.tipo <> 'responder' and not l.risco)) /* 0430 */ and (l.conversa_id is not null or l.venda_id is not null)$b$);
  execute d;
end $mig$;

commit;
